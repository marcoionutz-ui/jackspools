// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JackpotToken - Production Ready
 * @notice Fair launch token with community reward mechanics on BSC.
 * @notice The term "Jackpot" in this context does not refer to gambling or betting.
 *         It represents an automated reward mechanism that is randomly distributed back to the community.
 * @notice Participation is voluntary; the contract operates autonomously without external control.
 * @dev Implements buy tax, auto-liquidity, sell lock, and jackpot funding logic.
 */
 
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
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
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function sync() external;
}

interface IJackpotVault {
    function onTaxReceived() external payable; 
    function addEligibleBuyer(address buyer, uint256 bnbAmount) external;
    function getMinBuyForEligibility() external view returns (uint256);
    function getMinEligibilityTokens() external view returns (uint256);
}

interface IJackpotLPVault {
    function onLPTaxReceived() external payable; 
    function recordLPContribution(address user, uint256 bnbAmount) external;
}

contract JackpotToken is IERC20, ReentrancyGuard {
    // Balances and allowances
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) public sellUnlock; // Sell lock timestamp
	mapping(address => uint256) public lastBuyTime; // Buy cooldown timestamp
    mapping(address => bool) public isExempt; // Tax and lock exemptions
    
    // Token metadata
    string public constant name = "Jackpot Token";
    string public constant symbol = "JACKPOT";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_100_000_000 * 10**18; // 1.1B
    
    // Tax configuration (immutable)
	uint256 public constant BUY_TAX_JACKPOT_BPS = 775;  // 7.75%
	uint256 public constant BUY_TAX_LP_BPS = 200;       // 2%
	uint256 public constant BUY_TAX_BURN_BPS = 25;      // 0.25%
	uint256 public constant TOTAL_BUY_TAX_BPS = 1000;   // 10% total
	uint256 public constant SELL_TAX_LP_BPS = 1000;     // 10%
	uint256 public constant BPS = 10000;
	uint256 public constant SELL_LOCK_DURATION = 48 hours;
	uint256 public constant MIN_ELIGIBILITY_TOKENS = 50_000 * 10**18; // DEPRECATED - now in vault
	uint256 public constant MIN_BUY_STAGE_1 = 0.005 ether; // 0.005 BNB when LP < 10
	uint256 public constant MIN_BUY_STAGE_2 = 0.01 ether; // 0.01 BNB when LP 10-25
	uint256 public constant MIN_BUY_STAGE_3 = 0.015 ether; // 0.015 BNB when LP 25-50
	uint256 public constant MIN_BUY_STAGE_4 = 0.025 ether; // 0.025 BNB when LP > 50
	uint256 public constant LP_STAGE_1_THRESHOLD = 10 ether; // 10 BNB
	uint256 public constant LP_STAGE_2_THRESHOLD = 25 ether; // 25 BNB
	uint256 public constant LP_STAGE_3_THRESHOLD = 50 ether; // 50 BNB
	uint256 public constant BUY_COOLDOWN = 30; // 30 seconds between buys
	uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% max slippage
	uint256 public constant MAX_WALLET_LP_THRESHOLD = 250 ether; // 250 BNB LP value to remove limit
    
    // Contracts
    IUniswapV2Router02 public immutable router;
    address public immutable pair;
    address public immutable WBNB;
    IJackpotVault public vault;
	IJackpotLPVault public lpVault;
	address public lpManager; // Contract that handles LP additions
    
    // Swap configuration
    uint256 public minSwapTokens = 100 * 10**18; // 100 tokens minimum (for low LP launches)
    uint256 private _jackpotTokens;
    uint256 private _lpTokens;
	uint256 private _lpJackpotTokens;
	uint256 public lastProcessBlock;
    
    // State
    bool private _swapping;
	bool private _isLPAddition;
    bool public vaultLocked;
    bool public tradingEnabled;
    address public owner;
    
    // Constants
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    // Events
    event OwnershipRenounced();
    event VaultSet(address indexed vault);
    event TradingEnabled();
    event TaxProcessed(uint256 jackpotBNB, uint256 lpBNB, uint256 burnedTokens);
    event SellLockSet(address indexed account, uint256 unlockTime);
    event AutoLiquify(uint256 tokensSwapped, uint256 bnbReceived, uint256 liquidity);
    event MinSwapTokensUpdated(uint256 oldValue, uint256 newValue);
    event MaxWalletActive(bool active, uint256 limit);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier lockSwap() {
        _swapping = true;
        _;
        _swapping = false;
    }
    
    constructor(address _router) {
        require(_router != address(0), "Zero router");
        
        owner = msg.sender;
        router = IUniswapV2Router02(_router);
        WBNB = router.WETH();
        
        // Validate BSC deployment
        require(WBNB == BSC_WBNB, "Not BSC");
        
        // Create pair
        pair = IUniswapV2Factory(router.factory()).createPair(address(this), WBNB);
        require(pair != address(0), "Pair creation failed");
        
        // Setup exemptions
        isExempt[msg.sender] = true;
        isExempt[address(this)] = true;
        // isExempt[_router] = true;
        // isExempt[pair] = true;
        isExempt[DEAD] = true;
        
        // Mint supply
        _balances[msg.sender] = 100_000_000 * 10**18; // 100M to deployer
        _balances[address(this)] = 1_000_000_000 * 10**18; // 1B for liquidity
        
        emit Transfer(address(0), msg.sender, 100_000_000 * 10**18);
        emit Transfer(address(0), address(this), 1_000_000_000 * 10**18);
    }
    
    // One-time vault setter
    function setVault(address _vault) external onlyOwner {
        require(!vaultLocked, "Vault locked");
        require(_vault != address(0), "Zero vault");
        
        vault = IJackpotVault(_vault);
        vaultLocked = true;
		lpVault = IJackpotLPVault(address(0));
		lpManager = address(0);
        isExempt[_vault] = true;
        
        emit VaultSet(_vault);
    }
    
	/**
	 * @notice Set LP Vault address (one-time only)
	 * @param _lpVault Address of LP jackpot vault
	 */
	function setLPVault(address _lpVault) external onlyOwner {
		require(address(lpVault) == address(0), "LP Vault already set");
		require(_lpVault != address(0), "Invalid address");
		lpVault = IJackpotLPVault(_lpVault);
	}

	/**
	 * @notice Set LP Manager address (one-time only)
	 * @param _lpManager Address of LP manager contract
	 */
	function setLPManager(address _lpManager) external onlyOwner {
		require(lpManager == address(0), "LP Manager already set");
		require(_lpManager != address(0), "Invalid address");
		lpManager = _lpManager;
		isExempt[_lpManager] = true;
	}
	
    // Enable trading after liquidity added
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        require(vaultLocked, "Set vault first");
        tradingEnabled = true;
        emit TradingEnabled();
    }
    
    // Update minimum swap threshold
    function updateMinSwapTokens(uint256 _minSwapTokens) external onlyOwner {
        require(_minSwapTokens >= 100 * 10**18, "Too low"); // Min 100 tokens
        require(_minSwapTokens <= 100_000 * 10**18, "Too high"); // Max 100k tokens
        uint256 old = minSwapTokens;
        minSwapTokens = _minSwapTokens;
        emit MinSwapTokensUpdated(old, _minSwapTokens);
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }
    
    function allowance(address tokenOwner, address spender) public view override returns (uint256) {
		return _allowances[tokenOwner][spender];
	}
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		uint256 currentAllowance = _allowances[sender][msg.sender];
		require(currentAllowance >= amount, "Exceeds allowance");
		
		// Set flag if LP addition ONLY by LPManager (not router swaps!)
		if (msg.sender == lpManager && recipient == pair) {
			_isLPAddition = true;
		}
		
		// EFFECTS - UPDATE ALLOWANCE FIRST (BEFORE EXTERNAL CALLS!)
		
		if (currentAllowance != type(uint256).max) {
			_approve(sender, msg.sender, currentAllowance - amount);
		}
	
		// INTERACTIONS - EXTERNAL CALL AFTER STATE UPDATE!
		
		_transfer(sender, recipient, amount);
		
		// Reset flag
		_isLPAddition = false;
		
		return true;
	}
    
    function _approve(address tokenOwner, address spender, uint256 amount) private {
		require(tokenOwner != address(0), "From zero");
		require(spender != address(0), "To zero");
		
		_allowances[tokenOwner][spender] = amount;
		emit Approval(tokenOwner, spender, amount);
	}
    
    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "From zero");
        require(to != address(0), "To zero");
        require(amount > 0, "Zero amount");
        require(_balances[from] >= amount, "Insufficient balance");
        
        // Check trading status
        if (!tradingEnabled) {
            require(isExempt[from] || isExempt[to], "Trading not enabled");
        }
       
	   // Determine transaction type
		bool isBuy = from == pair;
		bool isSell = to == pair && from != address(this) && !_isLPAddition;
		
		// Block unauthorized liquidity pools (ONLY official pair allowed)
		if (!isExempt[from] && !isExempt[to]) {
			// Check if 'from' is an unauthorized pair
			if (from != pair && _isPair(from)) {
				revert("Unauthorized liquidity pool - use official pool only");
			}
			
			// Check if 'to' is an unauthorized pair
			if (to != pair && _isPair(to)) {
				revert("Unauthorized liquidity pool - use official pool only");
			}
		}

		// Check sell lock FIRST (independent of tax exemptions)
		// Exception: LP additions by Router/LPManager bypass sell lock
		if (isSell && !isExempt[from] && !_isLPAddition) {
			require(block.timestamp >= sellUnlock[from], "Sell locked 48h");
		}
        
		// Propagate sell lock on transfers (not to pair/router/exempt)
        if (from != pair && to != pair && !isExempt[to] && !isExempt[from]) {
            if (sellUnlock[from] > sellUnlock[to]) {
                sellUnlock[to] = sellUnlock[from];
                emit SellLockSet(to, sellUnlock[to]);
            }
        }
        
        bool takeTax = !_swapping && 
               !_isLPAddition &&  
               !isExempt[from] && 
               !isExempt[to] && 
               !isExempt[msg.sender] && 
               tradingEnabled;
        uint256 taxAmount = 0;
        
        // Buy tax
		if (takeTax && isBuy) {
			// Buy cooldown check (anti-spam)
			require(
				block.timestamp >= lastBuyTime[to] + BUY_COOLDOWN,
				"Wait 30s between buys"
			);
			lastBuyTime[to] = block.timestamp;
			
			taxAmount = (amount * TOTAL_BUY_TAX_BPS) / BPS;
			
			// Split tax components
			uint256 jackpotTokens = (amount * BUY_TAX_JACKPOT_BPS) / BPS;
			uint256 lpTokens = (amount * BUY_TAX_LP_BPS) / BPS;
			uint256 burnTokens = (amount * BUY_TAX_BURN_BPS) / BPS;
			
			_jackpotTokens += jackpotTokens;
			_lpTokens += lpTokens;
			
			// Burn immediately
			if (burnTokens > 0) {
				_balances[DEAD] += burnTokens;
				emit Transfer(from, DEAD, burnTokens);
			}
			
			// Set sell lock for buyer
			sellUnlock[to] = block.timestamp + SELL_LOCK_DURATION;
			emit SellLockSet(to, sellUnlock[to]);
		}
        
		// Sell tax - Split 50/50 (LP Jackpot + Auto LP)
		if (takeTax && isSell) {
			taxAmount = (amount * SELL_TAX_LP_BPS) / BPS;
			
			uint256 halfTax = taxAmount / 2;
			
			// 50% to LP Jackpot
			_lpJackpotTokens += halfTax;
			
			// 50% to Auto LP
			_lpTokens += (taxAmount - halfTax); // Remaining goes to LP (handles odd amounts)
		}

        // Execute transfer
        if (taxAmount > 0) {
            uint256 contractTax = taxAmount;
            _balances[address(this)] += contractTax;
            emit Transfer(from, address(this), contractTax);
        }

        // EFFECTS - UPDATE BALANCES & EMIT EVENTS (BEFORE EXTERNAL CALLS!)
              
        _balances[from] -= amount;
        _balances[to] += (amount - taxAmount);
        
        emit Transfer(from, to, amount - taxAmount);
        
        // Check max wallet limit AFTER balance is updated (still part of Effects)
        // Skip for: sells, exempt addresses, pair, and contract itself
        if (!isSell && !isExempt[to] && to != pair && to != address(this)) {
            uint256 maxWallet = getMaxWalletTokens();
            
            // If max is type(uint256).max, no limit applies
            if (maxWallet < type(uint256).max) {
                require(
                    _balances[to] <= maxWallet,
                    "Exceeds max wallet limit"
                );
            }
        }
		
        // INTERACTIONS - EXTERNAL CALLS (AFTER ALL STATE UPDATES!)
        
        // Process accumulated taxes (AUTO + MANUAL)
        // Simple condition: just check if we have enough tokens
        if (
            !_swapping &&
            isBuy &&
            !_isLPAddition &&
            _balances[address(this)] >= minSwapTokens &&
            vaultLocked &&
			block.number > lastProcessBlock
        ) {
			lastProcessBlock = block.number;
            // Try to process (fails silent if issues)
            try this.processTaxesInternal() {} catch {}
        }
        
        // Add buyer to eligible pool (after balance is confirmed updated)
        if (isBuy && vaultLocked && address(vault) != address(0)) {
            uint256 bnbValue = _getBNBValue(amount - taxAmount);
            try vault.addEligibleBuyer(to, bnbValue) {} catch {}
        }
    }
    
    function _processTaxes() private lockSwap {
    
		// Save to locals first
		uint256 localJackpot = _jackpotTokens;
		uint256 localLP = _lpTokens;
		uint256 localLPJackpot = _lpJackpotTokens;
		
		uint256 tokensToProcess = localJackpot + localLP + localLPJackpot;
		if (tokensToProcess == 0) return;
		
		// Reset storage (ONLY AFTER we confirm we have tokens)
		_jackpotTokens = 0;
		_lpTokens = 0;
		_lpJackpotTokens = 0;
		  
		// Use available contract balance
		uint256 contractBalance = _balances[address(this)];
		if (tokensToProcess > contractBalance) {
			tokensToProcess = contractBalance;
		}
		
		if (tokensToProcess == 0) return;
		
		// Calculate split proportionally
		uint256 totalTokens = localJackpot + localLP + localLPJackpot;
		uint256 lpHalf = (localLP * tokensToProcess) / totalTokens / 2;
		uint256 tokensToSwap = tokensToProcess - lpHalf;
				
		if (tokensToSwap > 0) {
			uint256 initialBalance = address(this).balance;
			
			// Calculate minimum output with slippage protection
			uint256 minOutput = _calculateMinOutput(tokensToSwap);
			
			address[] memory path = new address[](2);
			path[0] = address(this);
			path[1] = WBNB;
			
			_approve(address(this), address(router), tokensToSwap);
			
			try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
				tokensToSwap,
				minOutput,
				path,
				address(this),
				block.timestamp
			) {
				uint256 bnbReceived = address(this).balance - initialBalance;
				
				if (bnbReceived > 0) {
					// Calculate proportional split 
					uint256 bnbForJackpot = (bnbReceived * localJackpot) / tokensToSwap;
					uint256 bnbForLPJackpot = (bnbReceived * localLPJackpot) / tokensToSwap;
					uint256 bnbForLp = bnbReceived - bnbForJackpot - bnbForLPJackpot;

					// Send to buyer jackpot
					if (bnbForJackpot > 0 && address(vault) != address(0)) {
						try vault.onTaxReceived{value: bnbForJackpot}() {} catch {}
					}

					// Send to LP jackpot 
					if (bnbForLPJackpot > 0 && address(lpVault) != address(0)) {
						try lpVault.onLPTaxReceived{value: bnbForLPJackpot}() {} catch {}
					}
					
					// Add liquidity
					if (bnbForLp > 0 && lpHalf > 0) {
						_approve(address(this), address(router), lpHalf);
						
						try router.addLiquidityETH{value: bnbForLp}(
							address(this),
							lpHalf,
							0,
							0,
							DEAD, // Burn LP tokens
							block.timestamp
						) returns (uint256 tokenUsed, uint256 bnbUsed, uint256 liquidity) {
							emit AutoLiquify(tokenUsed, bnbUsed, liquidity);
						} catch {}
					}
					
					emit TaxProcessed(bnbForJackpot + bnbForLPJackpot, bnbForLp, 0);
				}
			} catch {
				// RESTORE variables if swap failed!
				_jackpotTokens = localJackpot;
				_lpTokens = localLP;
				_lpJackpotTokens = localLPJackpot;
			}
		}       
	}
    
    function _calculateMinOutput(uint256 tokenAmount) private view returns (uint256) {
		if (tokenAmount == 0) return 0;
		
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = WBNB;
		
		try router.getAmountsOut(tokenAmount, path) returns (uint[] memory amounts) {
			if (amounts.length >= 2 && amounts[1] > 0) {
				// Apply slippage protection (90% minimum)
				return (amounts[1] * (BPS - MAX_SLIPPAGE_BPS)) / BPS;
			}
		} catch {}
		
		return 0; // Fallback to 0 if calculation fails
	}
    
    function getLPValue() public view returns (uint256) {
		try IUniswapV2Pair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
			// Validate reserves are not zero
			if (reserve0 == 0 && reserve1 == 0) {
				return 0; // Before initial liquidity → strictest max wallet (but trading disabled anyway)
			}
			
			address token0 = IUniswapV2Pair(pair).token0();
			uint256 bnbReserve = token0 == WBNB ? reserve0 : reserve1;
			
			// Validate BNB reserve
			if (bnbReserve == 0) {
				return 0; // Edge case: token reserve exists but no BNB → strictest max wallet
			}
			
			return bnbReserve * 2; // Total LP value = 2x BNB reserve
		} catch {
			// Return high value to DISABLE max wallet limit on error
			// This is safer than returning 0 which activates strictest limit
			return 100 ether; // Returns Stage 5 threshold → no max wallet limit
		}
	}
	
	/**
	 * @notice Calculate BNB value of token amount
	 * @param tokenAmount Amount of tokens to evaluate
	 * @return BNB value in wei
	 */
	function _getBNBValue(uint256 tokenAmount) internal view returns (uint256) {
		if (tokenAmount == 0) return 0;
		
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = WBNB;
		
		try router.getAmountsOut(tokenAmount, path) returns (uint[] memory amounts) {
			if (amounts.length >= 2 && amounts[1] > 0) {
				return amounts[1]; // BNB value in wei
			}
		} catch {}
		
		return 0; // Fallback safe
	}
	
	/**
	 * @notice Get current minimum buy requirement based on LP value
	 */
	function getMinBuyForLastBuyer() public view returns (uint256) {
		uint256 lpValue = getLPValue();
		
		if (lpValue < 10 ether) {
			return 0.0025 ether; // Stage 1: $1.50 @ $600/BNB when LP < 10 BNB
		}
		
		if (lpValue < 25 ether) {
			return 0.00333 ether; // Stage 2: $2 @ $600/BNB when LP 10-25 BNB
		}
		
		if (lpValue < 50 ether) {
			return 0.00417 ether; // Stage 3: $2.50 @ $600/BNB when LP 25-50 BNB
		}
		
		if (lpValue < 100 ether) {
			return 0.005 ether; // Stage 4: $3 @ $600/BNB when LP 50-100 BNB
		}
		
		return 0.00583 ether; // Stage 5: $3.50 @ $600/BNB when LP > 100 BNB
	}
    
	/**
	 * @notice Get maximum wallet tokens based on LP value (dynamic scaling)
	 * @dev Top-tier thresholds for serious project growth
	 */
	function getMaxWalletTokens() public view returns (uint256) {
		uint256 lpValue = getLPValue();
		
		if (lpValue < 10 ether) {
			return 15_000_000 * 10**18; // 15M (1.36% supply) - Stage 1: Very strict early
		} else if (lpValue < 25 ether) {
			return 30_000_000 * 10**18; // 30M (2.7% supply) - Stage 2: Strict
		} else if (lpValue < 50 ether) {
			return 60_000_000 * 10**18; // 60M (5.4% supply) - Stage 3: Growth
		} else if (lpValue < 100 ether) {
			return 90_000_000 * 10**18; // 90M (8.1% supply) - Stage 4: Mature
		} else {
			return type(uint256).max; // NO LIMIT - Stage 5: Top tier (100+ BNB LP)
		}
	}
	
	/**
	 * @notice Check if address is a PancakeSwap pair contract
	 * @dev Works with any Uniswap V2 fork (PancakeSwap uses same interface)
	 */
	function _isPair(address account) private view returns (bool) {
		if (account.code.length == 0) return false; // Not a contract
		
		try IUniswapV2Pair(account).token0() returns (address) {
			return true; // Has token0() = is a liquidity pair
		} catch {
			return false; // Not a pair
		}
	}
	
    // Add initial liquidity
    function addInitialLiquidity() external payable onlyOwner {
        require(msg.value > 0, "Need BNB");
        require(!tradingEnabled, "Trading already enabled");
        
        uint256 tokenAmount = _balances[address(this)];
        require(tokenAmount > 0, "No tokens");
        
        _approve(address(this), address(router), tokenAmount);
        
        router.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            0,
            0,
            DEAD, // Burn initial LP
            block.timestamp
        );
    }
    
    // Emergency function to process stuck taxes (owner only, before renounce)
	function emergencyProcessTaxes() external onlyOwner {
		require(!_swapping, "Already processing");
		if (_jackpotTokens + _lpTokens > 0) {
			_processTaxes();
		}
		// Silent success if nothing to process
	}
    
    // Renounce ownership
    function renounceOwnership() external onlyOwner {
        require(tradingEnabled, "Enable trading first");
        require(vaultLocked, "Set vault first");
        owner = address(0);
        emit OwnershipRenounced();
    }
    
    // Recovery function for stuck BNB (owner only, before renounce)
    function recoverBNB() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB");
        (bool success,) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }
    
    // Check if max wallet limit is active
    function isMaxWalletActive() public view returns (bool) {
		return getMaxWalletTokens() < type(uint256).max;
	}
        
	// Get current max wallet limit (dynamic based on LP)
	function getMaxWalletLimit() public view returns (uint256) {
		return getMaxWalletTokens();
	}
    
    // Get LP threshold for removing max wallet
    function getMaxWalletLPThreshold() public pure returns (uint256) {
        return MAX_WALLET_LP_THRESHOLD;
    }
	
	/**
     * @notice Process accumulated taxes manually (anyone can call)
     * @dev Caller receives 0.3% reward from generated BNB
     */
    function processTaxes() external nonReentrant {
        require(_balances[address(this)] >= minSwapTokens, "Not enough tokens");
        _processTaxesWithReward(msg.sender);
    }
    
    /**
     * @notice Internal processing (auto-triggered from _transfer)
     */
    function processTaxesInternal() external {
        require(msg.sender == address(this), "Only self");
        _processTaxes();
    }
    
    /**
     * @notice Process taxes with optional caller reward
     */
    function _processTaxesWithReward(address caller) private lockSwap {
        uint256 bnbBefore = address(this).balance;
        
        _processTaxes();
        
        // Reward caller with 0.3% of generated BNB (not for auto-calls)
        if (caller != address(this) && caller != address(0)) {
            uint256 bnbGenerated = address(this).balance - bnbBefore;
            uint256 reward = (bnbGenerated * 30) / 10000; // 0.3%
            
            if (reward > 0) {
                (bool success,) = caller.call{value: reward}("");
                require(success, "Reward failed");
            }
        }
    }
    
    receive() external payable {}
}
