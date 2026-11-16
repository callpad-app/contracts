// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {MockERC20} from "../lib/solady/test/utils/mocks/MockERC20.sol";
import {Hook} from "../src/Hook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";

abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant PROOF_SIGNER_KEY = 1;
    uint256 internal constant BID = 10e6;
    uint256 internal constant PREBUY = 1000e6;
    uint256 internal constant PREBUY_FEE = 10e6;
    bytes32 internal constant HANDLE_ID = keccak256("handle");
    bytes32 internal constant OWN_HANDLE_ID = keccak256("own");

    address internal treasury = makeAddr("treasury");
    IPoolManager internal manager;
    PoolSwapTest internal router;
    MockERC20 internal usd;
    Launchpad internal launchpad;
    Hook internal hook;
    address internal token;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        router = new PoolSwapTest(manager);
        usd = new MockERC20("USD", "USD", 6);
        hook = Hook(
            address(
                uint160(
                    (0x4444 << 144) | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                )
            )
        );
        launchpad = new Launchpad(vm.addr(PROOF_SIGNER_KEY), treasury, address(usd), manager, hook);
        deployCodeTo("Hook.sol:Hook", abi.encode(manager, launchpad), address(hook));

        usd.mint(address(this), 1_000_000e6);
        usd.approve(address(launchpad), type(uint256).max);
        usd.approve(address(router), type(uint256).max);

        _trade(_launchWithPrebuy());
        ERC20(token).approve(address(router), type(uint256).max);
    }

    function _trade(address token_) internal {
        token = token_;
        key = PoolKey({
            currency0: Currency.wrap(address(usd)),
            currency1: Currency.wrap(token_),
            fee: 0,
            tickSpacing: launchpad.TICK_SPACING(),
            hooks: hook
        });
    }

    function _swap(bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 usdDelta, int256 tokenDelta, uint256 fee)
    {
        uint256 usdFeesBefore = _usdFees();
        vm.recordLogs();
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(_tokenFees(), 0);
        (usdDelta, tokenDelta, fee) = (delta.amount0(), delta.amount1(), _usdFees() - usdFeesBefore);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(_swappedData(), abi.encode(usdDelta, tokenDelta, fee, sqrtPriceX96));
    }

    function _swappedData() internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != Hook.Swapped.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(token))));
            data = logs[i].data;
        }
    }

    function _usdFees() internal view returns (uint256) {
        return manager.balanceOf(address(hook), key.currency0.toId());
    }

    function _tokenFees() internal view returns (uint256) {
        return manager.balanceOf(address(hook), key.currency1.toId());
    }

    function _launchWithPrebuy() internal returns (address) {
        bytes32 handleId = _startAuction("Handle", "handle");
        launchpad.prebuy(handleId, PREBUY);
        skip(launchpad.auctionDuration());
        return launchpad.launch(handleId);
    }

    function _startAuction(string memory name, string memory symbol) internal returns (bytes32 handleId) {
        handleId = keccak256(bytes(symbol));
        bytes memory proof = _prove(
            keccak256(
                abi.encode(
                    Proofs.START_AUCTION_TYPEHASH,
                    keccak256(bytes(name)),
                    keccak256(bytes(symbol)),
                    BID,
                    block.timestamp
                )
            )
        );

        launchpad.startAuction(name, symbol, _validSalt(handleId), BID, block.timestamp, proof);
    }

    function _launchOwn(address owner) internal returns (address) {
        string memory name = "Own";
        string memory symbol = "own";
        bytes memory proof = _prove(
            keccak256(
                abi.encode(
                    Proofs.LAUNCH_OWN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), owner, block.timestamp
                )
            )
        );

        bytes32 salt = _validSalt(keccak256(bytes(symbol)));

        vm.prank(owner);
        return launchpad.launchOwn(name, symbol, salt, block.timestamp, proof);
    }

    function _setAccount(bytes32 handleId, address account) internal {
        bytes memory proof = _accountProof(handleId, account);

        vm.prank(account);
        launchpad.setAccount(handleId, block.timestamp, proof);
    }

    function _accountProof(bytes32 handleId, address account) internal view returns (bytes memory) {
        return _prove(keccak256(abi.encode(Proofs.SET_ACCOUNT_TYPEHASH, handleId, account, block.timestamp)));
    }

    function _prove(bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Callpad"),
                keccak256("1"),
                block.chainid,
                launchpad
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PROOF_SIGNER_KEY, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _validSalt(bytes32 handleId) internal view returns (bytes32 salt) {
        while (true) {
            try launchpad.predictToken(handleId, salt) {
                return salt;
            } catch {
                salt = bytes32(uint256(salt) + 1);
            }
        }
    }
}
