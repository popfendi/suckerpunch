// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PopFendisSuckerPunch} from "../src/PopFendisSuckerPunch.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";


contract SuckerPunchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PopFendisSuckerPunch sp;
    PoolId poolId;

    Currency public constant NATIVE = Currency.wrap(address(0));

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PopFendisSuckerPunch).creationCode, abi.encode(address(manager)));
        sp = new PopFendisSuckerPunch{salt: salt}(IPoolManager(address(manager)));
        require(address(sp) == hookAddress, "SuckerPunch: hook address mismatch");

       /* // Create the pool
        key = PoolKey(NATIVE, currency1, 3000, 60, IHooks(address(sp)));
        poolId = key.toId();
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether),
            ZERO_BYTES
        ); */

        (key, poolId) = initPoolAndAddLiquidityETH(
        NATIVE,
        currency1,
        IHooks(address(sp)),
        SwapFeeLibrary.DYNAMIC_FEE_FLAG,
        SQRT_RATIO_1_1,
        ZERO_BYTES,
        100 ether
    );

    }
    

    function testSandwich() public {
        address user1 = vm.addr(0x1);
        vm.deal(user1, .2 ether);
        vm.startPrank(user1, tx.origin);
        
        uint preBal = user1.balance;
        console.log("pre balance: %d", user1.balance);

        bool zeroForOne = true;
        int256 amountSpecified = -0.1 ether;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        uint postBalance = currency1.balanceOf(user1);
        console.log(postBalance);

        address[1] memory toApprove = [
            address(swapRouter)
        ];

        address currencyaddy = Currency.unwrap(currency1);
        MockERC20 erc20 = MockERC20(currencyaddy);

        erc20.approve(address(swapRouter), type(uint256).max);
        zeroForOne = false;
        amountSpecified = int256(postBalance);
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        uint postBal = user1.balance - 0.1 ether;
        console.log("post balance: %d", user1.balance);

        // balance should be less than 90% of original buy price
        assertTrue(postBal < 0.09 ether);
        vm.stopPrank();
    }
    

}
