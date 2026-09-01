// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";

contract DriftSchedulerMock {
    uint256 public nextId;
    uint32 public lastCalls;
    uint32 public lastFrequency;
    mapping(uint256 => bool) public cancelled;

    function approveScheduler(address) external {}

    function schedule(bytes calldata, uint32, uint32, uint32 calls, uint32 frequency, uint32, uint256, uint256, uint256, address)
        external
        returns (uint256)
    {
        lastCalls = calls;
        lastFrequency = frequency;
        return ++nextId;
    }

    function cancel(uint256 callId) external {
        cancelled[callId] = true;
    }

    function getCallState(uint256) external pure returns (uint8) {
        return 0;
    }
}

contract DriftWalletMock {
    mapping(address => uint256) private balances;
    mapping(address => uint256) public lockUntil;

    function deposit(uint256 duration) external payable {
        balances[msg.sender] += msg.value;
        lockUntil[msg.sender] = block.number + duration;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}

contract DriftRegistryMock {
    address public executor;
    bool public available;

    function configure(address executor_, bool available_) external {
        executor = executor_;
        available = available_;
    }

    function pickServiceByCapability(uint8, bool, uint256, uint256) external view returns (address, bool) {
        return (executor, available);
    }
}

contract DriftHttpMock {
    struct Response {
        uint16 status;
        bytes body;
        string errorMessage;
        bool shouldRevert;
    }

    mapping(bytes32 => Response) private responses;

    function configure(string calldata url, uint16 status, bytes calldata body, string calldata errorMessage, bool shouldRevert) external {
        responses[keccak256(bytes(url))] = Response(status, body, errorMessage, shouldRevert);
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        Response storage response = responses[_urlKey(input)];
        if (response.shouldRevert) revert("feed call reverted");
        bytes memory inner = abi.encode(response.status, new string[](0), new string[](0), response.body, response.errorMessage);
        return abi.encode(input, inner);
    }

    function _urlKey(bytes calldata input) private pure returns (bytes32) {
        uint256 relativeOffset;
        uint256 length;
        assembly {
            relativeOffset := calldataload(add(input.offset, 160))
            length := calldataload(add(input.offset, relativeOffset))
        }
        bytes memory urlBytes = new bytes(length);
        assembly {
            calldatacopy(add(urlBytes, 32), add(add(input.offset, relativeOffset), 32), length)
        }
        return keccak256(urlBytes);
    }
}

contract DriftJqMock {
    mapping(bytes32 => uint256) private values;
    mapping(bytes32 => bool) private known;

    function configure(string calldata path, string calldata json, uint256 value) external {
        bytes32 key = keccak256(abi.encode(path, json));
        values[key] = value;
        known[key] = true;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        (string memory path, string memory json,) = abi.decode(input, (string, string, uint8));
        bytes32 key = keccak256(abi.encode(path, json));
        require(known[key], "missing jq fixture");
        return abi.encode(values[key]);
    }
}

contract DriftGuardTest is Test {
    address constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address constant WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address constant REGISTRY = 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F;
    address constant HTTP = address(0x0801);
    address constant JQ = address(0x0803);
    address constant EXECUTOR = address(0xD12F7);

    RitualPredict drift;
    address aya = makeAddr("aya");
    address bilal = makeAddr("bilal");
    address dina = makeAddr("dina");
    address yassir = makeAddr("yassir");

    function setUp() public {
        vm.etch(SCHEDULER, address(new DriftSchedulerMock()).code);
        vm.etch(WALLET, address(new DriftWalletMock()).code);
        vm.etch(REGISTRY, address(new DriftRegistryMock()).code);
        vm.etch(HTTP, address(new DriftHttpMock()).code);
        vm.etch(JQ, address(new DriftJqMock()).code);
        DriftRegistryMock(REGISTRY).configure(EXECUTOR, true);
        drift = new RitualPredict(1000);
        vm.deal(aya, 100 ether);
        vm.deal(bilal, 100 ether);
        vm.deal(dina, 100 ether);
        vm.deal(yassir, 100 ether);
        _feed(1000);
    }

    function _params() private pure returns (RitualPredict.NewMarket memory p) {
        p.question = "Will the usage metric drift by more than 5 percent from 1000?";
        p.dataUrl = "https://drift-feed.example.test/metric";
        p.jsonPath = ".metric";
        p.referenceValue = 1000;
        p.toleranceBps = 500;
        p.bettingSeconds = 40;
        p.resolveDelaySeconds = 20;
    }

    function _feed(uint256 value) private {
        string memory body = "{\"metric\":1000}";
        DriftHttpMock(HTTP).configure(_params().dataUrl, 200, bytes(body), "", false);
        DriftJqMock(JQ).configure(_params().jsonPath, body, value);
    }

    function _create() private returns (uint256) {
        return drift.createMarket(_params());
    }

    function _bet(uint256 id, address account, RitualPredict.Outcome side, uint256 amount) private {
        vm.prank(account);
        drift.bet{value: amount}(id, side);
    }

    function _deliver(uint256 id, uint256 executionIndex) private {
        vm.prank(SCHEDULER);
        drift.onScheduledResolve(executionIndex, id);
    }

    function test_CreationSchedulesThreeRetriesAndFundingWorks() public {
        uint256 id = _create();
        RitualPredict.Market memory m = drift.getMarket(id);
        assertEq(m.referenceValue, 1000);
        assertEq(m.toleranceBps, 500);
        assertEq(DriftSchedulerMock(SCHEDULER).lastCalls(), 3);
        assertEq(DriftSchedulerMock(SCHEDULER).lastFrequency(), 180);
        drift.fundExecution{value: 4 ether}(700);
        assertEq(drift.executionBalance(), 4 ether);
    }

    function test_InvalidReferenceAndWideToleranceAreRejected() public {
        RitualPredict.NewMarket memory p = _params();
        p.referenceValue = 0;
        vm.expectRevert(RitualPredict.BadConfiguration.selector);
        drift.createMarket(p);

        p = _params();
        p.toleranceBps = 5001;
        vm.expectRevert(RitualPredict.BadConfiguration.selector);
        drift.createMarket(p);
    }

    function test_BetsCloseAtCloseBlock() public {
        uint256 id = _create();
        RitualPredict.Market memory m = drift.getMarket(id);
        vm.roll(m.closeBlock);
        vm.prank(aya);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        drift.bet{value: 1 ether}(id, RitualPredict.Outcome.Stable);
    }

    function test_OnlySchedulerCanResolve() public {
        uint256 id = _create();
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        drift.onScheduledResolve(0, id);
    }

    function test_StableWinsWhenDriftEqualsTolerance() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 1 ether);
        _bet(id, bilal, RitualPredict.Outcome.UpDrift, 1 ether);
        _feed(1050);
        _deliver(id, 0);
        RitualPredict.Market memory m = drift.getMarket(id);
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Stable));
        assertEq(m.driftBps, 500);
        assertTrue(DriftSchedulerMock(SCHEDULER).cancelled(m.scheduleId));
    }

    function test_UpDriftWinsAboveTolerance() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.UpDrift, 2 ether);
        _bet(id, bilal, RitualPredict.Outcome.Stable, 1 ether);
        _feed(1061);
        _deliver(id, 0);
        assertEq(uint256(drift.getMarket(id).outcome), uint256(RitualPredict.Outcome.UpDrift));
        assertEq(drift.getMarket(id).driftBps, 610);
    }

    function test_DownDriftWinsBelowNegativeTolerance() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.DownDrift, 1 ether);
        _feed(930);
        _deliver(id, 0);
        assertEq(uint256(drift.getMarket(id).outcome), uint256(RitualPredict.Outcome.DownDrift));
        assertEq(drift.getMarket(id).driftBps, -700);
    }

    function test_WinningAccountClaimsShareAcrossThreePools() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.UpDrift, 1 ether);
        _bet(id, bilal, RitualPredict.Outcome.UpDrift, 3 ether);
        _bet(id, dina, RitualPredict.Outcome.Stable, 2 ether);
        _bet(id, yassir, RitualPredict.Outcome.DownDrift, 2 ether);
        _feed(1080);
        _deliver(id, 0);
        uint256 before = aya.balance;
        vm.prank(aya);
        drift.claimWinnings(id);
        assertEq(aya.balance - before, 2 ether);
    }

    function test_EmptyWinnerPoolInvalidatesAndRefunds() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 2 ether);
        _feed(1200);
        _deliver(id, 0);
        assertEq(uint256(drift.getMarket(id).state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(drift.claimable(id, aya), 2 ether);
        uint256 before = aya.balance;
        vm.prank(aya);
        drift.claimRefund(id);
        assertEq(aya.balance - before, 2 ether);
    }

    function test_FailuresRetryUntilThirdAttemptInvalidates() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 1 ether);
        DriftHttpMock(HTTP).configure(_params().dataUrl, 503, bytes("{}"), "", false);
        _deliver(id, 0);
        assertEq(uint256(drift.getMarket(id).state), uint256(RitualPredict.MarketState.Resolving));
        _deliver(id, 1);
        assertEq(drift.getMarket(id).attempts, 2);
        _deliver(id, 2);
        assertEq(uint256(drift.getMarket(id).state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(drift.getMarket(id).invalidReason, "HTTP status not successful");
    }

    function test_LateSuccessfulRetryCanResolve() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.DownDrift, 1 ether);
        DriftHttpMock(HTTP).configure(_params().dataUrl, 503, bytes("{}"), "", false);
        _deliver(id, 0);
        _feed(900);
        _deliver(id, 1);
        assertEq(uint256(drift.getMarket(id).outcome), uint256(RitualPredict.Outcome.DownDrift));
        assertEq(drift.getMarket(id).attempts, 2);
    }

    function test_ReplayedEarlierExecutionCannotIncrementAttempts() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 1 ether);
        DriftHttpMock(HTTP).configure(_params().dataUrl, 500, bytes("{}"), "", false);
        _deliver(id, 0);
        _deliver(id, 0);
        assertEq(drift.getMarket(id).attempts, 1);
    }

    function test_JqFailureUsesRetryBudget() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 1 ether);
        DriftHttpMock(HTTP).configure(_params().dataUrl, 200, bytes("{\"metric\":999}"), "", false);
        _deliver(id, 0);
        assertEq(uint256(drift.getMarket(id).state), uint256(RitualPredict.MarketState.Resolving));
        assertEq(drift.getMarket(id).invalidReason, "");
    }

    function test_ExpiryInvalidatesAfterLastRetryWindow() public {
        uint256 id = _create();
        _bet(id, aya, RitualPredict.Outcome.Stable, 1 ether);
        RitualPredict.Market memory m = drift.getMarket(id);
        vm.roll(uint256(m.resolveBlock) + uint256(drift.MAX_ATTEMPTS() - 1) * drift.RETRY_INTERVAL_BLOCKS() + 151);
        drift.expireMarket(id);
        assertEq(uint256(drift.getMarket(id).state), uint256(RitualPredict.MarketState.Invalid));
    }
}
