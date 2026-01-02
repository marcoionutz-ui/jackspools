// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LPManager - Liquidity Management Gateway
 * @notice Coordinates LP additions and records contributions for the LP Reward system.
 * @notice Operates as the on-chain bridge between users, the Uniswap V2 router, and the LPVault.
 * @dev Users add LP through this contract (via frontend) to become eligible for LP Reward rounds.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
	function allowance(address owner, address spender) external view returns (uint256);
}

interface IJACKsPools {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
	function PAIR() external view returns (address);
}

interface IJACKsLPVault {
    function recordLpContribution(address user, uint256 ethAmount) external;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Router02 {
	function factory() external pure returns (address);
	function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract JACKsLPManager is ReentrancyGuard {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
	IJACKsPools public immutable TOKEN;
	IJACKsLPVault public immutable LP_VAULT;
    IUniswapV2Router02 public immutable ROUTER;
	address public immutable WETH;
    IUniswapV2Pair public immutable PAIR;
    
    event LPAdded(
		address indexed user,
		uint256 tokenAmount,
		uint256 ethAmount,
		uint256 liquidity
	);
    
    constructor(
		address _token,
		address _lpVault,
		address _router
	) {
		require(_token != address(0), "Zero token");
		require(_lpVault != address(0), "Zero vault");
		require(_router != address(0), "Zero router");
		
		TOKEN = IJACKsPools(_token);
		LP_VAULT = IJACKsLPVault(_lpVault);
		ROUTER = IUniswapV2Router02(_router);
		
		// Store WETH and PAIR
		WETH = ROUTER.WETH();
		PAIR = IUniswapV2Pair(TOKEN.PAIR());
		require(address(PAIR) != address(0), "Pair not created");
	}
    
	/**
	 * @notice Calculate exact ETH needed for token amount
	 */
	function quoteEthForTokens(uint256 tokenAmount) public view returns (uint256 ethNeeded) {
		(uint112 r0, uint112 r1,) = PAIR.getReserves();
		
		(uint256 reserveToken, uint256 reserveWeth) = 
			(PAIR.token0() == address(TOKEN)) 
				? (uint256(r0), uint256(r1)) 
				: (uint256(r1), uint256(r0));
		
		require(reserveToken > 0 && reserveWeth > 0, "No reserves");
		ethNeeded = (tokenAmount * reserveWeth) / reserveToken;
	}

	/**
	 * @notice Calculate exact tokens needed for ETH amount
	 */
	function quoteTokensForEth(uint256 ethAmount) public view returns (uint256 tokenNeeded) {
		(uint112 r0, uint112 r1,) = PAIR.getReserves();
		
		(uint256 reserveToken, uint256 reserveWeth) = 
			(PAIR.token0() == address(TOKEN)) 
				? (uint256(r0), uint256(r1)) 
				: (uint256(r1), uint256(r0));
		
		require(reserveToken > 0 && reserveWeth > 0, "No reserves");
		tokenNeeded = (ethAmount * reserveToken) / reserveWeth;
	}
	
    /**
	 * @notice Add liquidity and register for LP Reward Rounds
	 * @dev User must approve tokens to this contract first
	 * @dev User must send EXACT ETH amount (use quoteEthForTokens helper)
	 * @param tokenAmount Amount of tokens to add
	 * @param tokenMin Minimum tokens (slippage protection)
	 * @param ethMin Minimum ETH (slippage protection)
	 * @param deadline Transaction deadline
	 */
	function addLiquidityAndRegister(
		uint256 tokenAmount,
		uint256 tokenMin,
		uint256 ethMin,
		uint256 deadline
	) external payable nonReentrant returns (
		uint256 addedTokens,
		uint256 addedEth,
		uint256 liquidity
	) {
		require(msg.value > 0, "No ETH sent");
		require(tokenAmount > 0, "No tokens specified");
		
		// Transfer tokens from user to this contract
		require(
			TOKEN.transferFrom(msg.sender, address(this), tokenAmount),
			"Token transfer failed"
		);
		
		// Approve router to spend tokens
		TOKEN.approve(address(ROUTER), 0);
		require(
			TOKEN.approve(address(ROUTER), tokenAmount),
			"Approval failed"
		);
		
		// Add liquidity (LP tokens are sent to DEAD)
		(addedTokens, addedEth, liquidity) = ROUTER.addLiquidityETH{value: msg.value}(
			address(TOKEN),
			tokenAmount,
			tokenMin,
			ethMin,
			DEAD,
			deadline
		);
		
		// CRITICAL: Force exact ETH usage (no refund = no griefing)
		require(addedEth == msg.value, "Requote ETH");
		
		// Reset router allowance to 0 (security hardening)
		uint256 remainingAllowance = IERC20(address(TOKEN)).allowance(address(this), address(ROUTER));
		if (remainingAllowance > 0) {
			require(TOKEN.approve(address(ROUTER), 0), "Allowance reset failed");
		}
		
		// Refund excess tokens if any
		uint256 excessTokens = tokenAmount - addedTokens;
		if (excessTokens > 0) {
			require(
				IERC20(address(TOKEN)).transfer(msg.sender, excessTokens),
				"Refund failed"
			);
		}
		
		// Record contribution in LP Vault (if meets minimum)
		LP_VAULT.recordLpContribution(msg.sender, addedEth);
		
		emit LPAdded(msg.sender, addedTokens, addedEth, liquidity);

		return (addedTokens, addedEth, liquidity);
	}
        
    receive() external payable {
		// Accept ETH refund from Router during LP addition
		// Reject direct ETH deposits from users
		require(
			msg.sender == address(ROUTER),
			"Use addLiquidityAndRegister"
		);
	}

}
