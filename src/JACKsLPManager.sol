// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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
}

interface IJACKsLPVault {
    function recordLpContribution(address user, uint256 ethAmount) external;
}

interface IUniswapV2Router02 {
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
	}
    
    /**
	 * @notice Add liquidity and register for LP Reward Rounds
	 * @dev User must approve tokens to this contract first
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
        
        // Refund excess ETH if any
		uint256 excessEth = msg.value - addedEth;
		if (excessEth > 0) {
			(bool success, ) = payable(msg.sender).call{value: excessEth}("");
			require(success, "ETH refund failed");
		}
        
        // Record contribution in LP Vault (if meets minimum)
		// No try-catch - transparency over silent fails
		// Users must meet minimum requirements to participate in LP Reward Rounds
		// Alternative: Add LP directly via DEX (no reward round participation)
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
