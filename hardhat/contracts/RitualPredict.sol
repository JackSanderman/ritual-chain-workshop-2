// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * DriftGuard resolves a market by measuring relative movement from a fixed reference.
 * The observed value is read through Ritual HTTP + jq. Bettors choose whether the
 * final reading drifted down, stayed within tolerance, or drifted up.
 */
contract RitualPredict {
    enum MarketState {
        Open,
        Closed,
        Resolving,
        Resolved,
        Invalid
    }

    enum Outcome {
        Unresolved,
        DownDrift,
        Stable,
        UpDrift
    }

    struct Market {
        uint256 id;
        address creator;
        string question;
        string dataUrl;
        string jsonPath;
        uint256 referenceValue;
        uint16 toleranceBps;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        uint256 totalDown;
        uint256 totalStable;
        uint256 totalUp;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        int256 driftBps;
        string invalidReason;
    }

    struct NewMarket {
        string question;
        string dataUrl;
        string jsonPath;
        uint256 referenceValue;
        uint16 toleranceBps;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 180;
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;
    uint256 public constant HTTP_TTL_BLOCKS = 100;
    uint256 public constant EXECUTOR_PROBES = 8;
    uint16 public constant MAX_TOLERANCE_BPS = 5_000;
    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    uint256 public immutable blockTimeMs;
    uint256 public marketCount;

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(address => mapping(Outcome => uint256))) public stakeOf;
    mapping(uint256 => mapping(address => bool)) public settled;

    event MarketCreated(uint256 indexed marketId, address indexed creator, uint64 closeBlock, uint64 resolveBlock, uint256 scheduleId);
    event DriftRuleSet(uint256 indexed marketId, uint256 referenceValue, uint16 toleranceBps, string jsonPath);
    event BetPlaced(uint256 indexed marketId, address indexed bettor, Outcome indexed side, uint256 amount);
    event ResolutionAttempted(uint256 indexed marketId, uint8 attempt, address executor);
    event ResolutionFailed(uint256 indexed marketId, uint8 attempt, string reason);
    event MarketResolved(uint256 indexed marketId, Outcome outcome, uint256 observedValue, int256 driftBps);
    event MarketInvalidated(uint256 indexed marketId, string reason);
    event WinningsClaimed(uint256 indexed marketId, address indexed account, uint256 amount);
    event StakeRefunded(uint256 indexed marketId, address indexed account, uint256 amount);

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error EmptyString();
    error BadConfiguration();
    error InvalidSide();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error TransferFailed();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadConfiguration();
        blockTimeMs = blockTimeMs_;
        IScheduler(RitualChain.SCHEDULER).approveScheduler(RitualChain.SCHEDULER);
    }

    function createMarket(NewMarket calldata p) external returns (uint256 marketId) {
        if (bytes(p.question).length == 0 || bytes(p.dataUrl).length == 0 || bytes(p.jsonPath).length == 0) {
            revert EmptyString();
        }
        if (p.referenceValue == 0 || p.toleranceBps > MAX_TOLERANCE_BPS) revert BadConfiguration();
        if (p.bettingSeconds < MIN_BETTING_SECONDS || p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS) {
            revert BadConfiguration();
        }
        if (p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS) revert BadConfiguration();

        uint256 close = block.number + _secondsToBlocks(p.bettingSeconds);
        uint256 resolveAt = close + _secondsToBlocks(p.resolveDelaySeconds);
        if (resolveAt > type(uint64).max) revert BadConfiguration();

        marketId = ++marketCount;
        Market storage m = _markets[marketId];
        m.id = marketId;
        m.creator = msg.sender;
        m.question = p.question;
        m.dataUrl = p.dataUrl;
        m.jsonPath = p.jsonPath;
        m.referenceValue = p.referenceValue;
        m.toleranceBps = p.toleranceBps;
        m.closeBlock = uint64(close);
        m.resolveBlock = uint64(resolveAt);
        m.state = MarketState.Open;
        m.scheduleId = _scheduleResolution(marketId, uint64(resolveAt));

        emit MarketCreated(marketId, msg.sender, m.closeBlock, m.resolveBlock, m.scheduleId);
        emit DriftRuleSet(marketId, p.referenceValue, p.toleranceBps, p.jsonPath);
    }

    function bet(uint256 marketId, Outcome side) external payable {
        Market storage m = _market(marketId);
        if (side == Outcome.Unresolved) revert InvalidSide();
        if (msg.value == 0) revert ZeroStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock) revert BettingClosed();

        stakeOf[marketId][msg.sender][side] += msg.value;
        if (side == Outcome.DownDrift) m.totalDown += msg.value;
        else if (side == Outcome.Stable) m.totalStable += msg.value;
        else if (side == Outcome.UpDrift) m.totalUp += msg.value;
        else revert InvalidSide();

        emit BetPlaced(marketId, msg.sender, side, msg.value);
    }

    function onScheduledResolve(uint256 executionIndex, uint256 marketId) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();
        Market storage m = _market(marketId);
        if (m.state == MarketState.Resolved || m.state == MarketState.Invalid) return;
        if (executionIndex >= MAX_ATTEMPTS || executionIndex < m.attempts) return;

        uint8 attempt = uint8(executionIndex + 1);
        m.attempts = attempt;
        m.state = MarketState.Resolving;

        address executor = _pickExecutor(marketId, executionIndex);
        emit ResolutionAttempted(marketId, attempt, executor);
        if (executor == address(0)) {
            _fail(m, marketId, attempt, "no HTTP executor");
            return;
        }

        (bool ok, uint256 value, string memory reason) = _readValue(m.dataUrl, m.jsonPath, executor);
        if (!ok) {
            _fail(m, marketId, attempt, reason);
            return;
        }

        int256 drift = _driftBps(value, m.referenceValue);
        Outcome result = _classify(drift, m.toleranceBps);
        m.observedValue = value;
        m.driftBps = drift;
        _resolve(m, marketId, result);
    }

    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 stake = stakeOf[marketId][msg.sender][m.outcome];
        if (stake == 0) revert NothingToClaim();
        uint256 payout = stake * _totalPool(m) / _poolFor(m, m.outcome);

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = stakeOf[marketId][msg.sender][Outcome.DownDrift]
            + stakeOf[marketId][msg.sender][Outcome.Stable]
            + stakeOf[marketId][msg.sender][Outcome.UpDrift];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    function expireMarket(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state == MarketState.Resolved || m.state == MarketState.Invalid) return;
        uint256 lastAttemptBlock = uint256(m.resolveBlock) + uint256(MAX_ATTEMPTS - 1) * RETRY_INTERVAL_BLOCKS;
        if (block.number <= lastAttemptBlock + SCHEDULER_TTL_BLOCKS) revert BettingClosed();
        _invalidate(m, marketId, "scheduled drift reads expired");
    }

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        if (m.state == MarketState.Open && block.number >= m.closeBlock) m.state = MarketState.Closed;
    }

    function getMarkets() external view returns (Market[] memory all) {
        all = new Market[](marketCount);
        for (uint256 i; i < marketCount; ++i) all[i] = getMarket(marketCount - i);
    }

    function claimable(uint256 marketId, address account) external view returns (uint256) {
        Market storage m = _market(marketId);
        if (settled[marketId][account]) return 0;
        if (m.state == MarketState.Invalid) {
            return stakeOf[marketId][account][Outcome.DownDrift]
                + stakeOf[marketId][account][Outcome.Stable]
                + stakeOf[marketId][account][Outcome.UpDrift];
        }
        if (m.state != MarketState.Resolved) return 0;
        uint256 stake = stakeOf[marketId][account][m.outcome];
        return stake == 0 ? 0 : stake * _totalPool(m) / _poolFor(m, m.outcome);
    }

    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(lockDurationBlocks);
    }

    function executionBalance() external view returns (uint256) {
        return IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    function decodeHttpResponse(bytes calldata raw) external pure returns (uint16 status, bytes memory body, string memory errorMessage) {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(actualOutput, (uint16, string[], string[], bytes, string));
    }

    function _readValue(string storage url, string storage path, address executor) private returns (bool, uint256, string memory) {
        bytes memory input = abi.encode(
            executor,
            new bytes[](0),
            HTTP_TTL_BLOCKS,
            new bytes[](0),
            bytes(""),
            url,
            RitualChain.HTTP_GET,
            new string[](0),
            new string[](0),
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );

        (bool callOk, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(input);
        if (!callOk) return (false, 0, "HTTP precompile reverted");

        try this.decodeHttpResponse(raw) returns (uint16 status, bytes memory body, string memory err) {
            if (bytes(err).length != 0) return (false, 0, err);
            if (status < 200 || status >= 300) return (false, 0, "HTTP status not successful");
            (bool jqOk, bytes memory output) =
                RitualChain.JQ_PRECOMPILE.staticcall(abi.encode(path, string(body), RitualChain.JQ_OUT_UINT256));
            if (!jqOk || output.length < 32) return (false, 0, "jq extraction failed");
            return (true, abi.decode(output, (uint256)), "");
        } catch {
            return (false, 0, "malformed HTTP response");
        }
    }

    function _fail(Market storage m, uint256 marketId, uint8 attempt, string memory reason) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _resolve(Market storage m, uint256 marketId, Outcome result) private {
        m.outcome = result;
        if (_poolFor(m, result) == 0) {
            _invalidate(m, marketId, "winning drift bucket has no stake");
            return;
        }
        m.state = MarketState.Resolved;
        _cancelQuietly(m.scheduleId);
        emit MarketResolved(marketId, result, m.observedValue, m.driftBps);
    }

    function _invalidate(Market storage m, uint256 marketId, string memory reason) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        _cancelQuietly(m.scheduleId);
        emit MarketInvalidated(marketId, reason);
    }

    function _classify(int256 drift, uint16 toleranceBps) private pure returns (Outcome) {
        int256 tolerance = int256(uint256(toleranceBps));
        if (drift < -tolerance) return Outcome.DownDrift;
        if (drift > tolerance) return Outcome.UpDrift;
        return Outcome.Stable;
    }

    function _driftBps(uint256 observed, uint256 referenceValue) private pure returns (int256) {
        if (observed >= referenceValue) {
            return int256((observed - referenceValue) * 10_000 / referenceValue);
        }
        return -int256((referenceValue - observed) * 10_000 / referenceValue);
    }

    function _poolFor(Market storage m, Outcome side) private view returns (uint256) {
        if (side == Outcome.DownDrift) return m.totalDown;
        if (side == Outcome.Stable) return m.totalStable;
        if (side == Outcome.UpDrift) return m.totalUp;
        return 0;
    }

    function _totalPool(Market storage m) private view returns (uint256) {
        return m.totalDown + m.totalStable + m.totalUp;
    }

    function _pickExecutor(uint256 marketId, uint256 executionIndex) private view returns (address) {
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, marketId, executionIndex, address(this))));
        try ITEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY).pickServiceByCapability(
            RitualChain.CAPABILITY_HTTP_CALL, true, seed, EXECUTOR_PROBES
        ) returns (address executor, bool found) {
            return found ? executor : address(0);
        } catch {
            return address(0);
        }
    }

    function _scheduleResolution(uint256 marketId, uint64 resolveBlock) private returns (uint256) {
        bytes memory data = abi.encodeCall(this.onScheduledResolve, (uint256(0), marketId));
        return IScheduler(RitualChain.SCHEDULER).schedule(
            data,
            RESOLVE_GAS_LIMIT,
            uint32(resolveBlock),
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            2 gwei,
            1 gwei,
            0,
            address(this)
        );
    }

    function _cancelQuietly(uint256 scheduleId) private {
        (bool ignored,) = RitualChain.SCHEDULER.call(abi.encodeCall(IScheduler.cancel, (scheduleId)));
        ignored;
    }

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _secondsToBlocks(uint256 seconds_) private view returns (uint256 blocks_) {
        blocks_ = seconds_ * 1000 / blockTimeMs;
        if (blocks_ == 0) blocks_ = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
