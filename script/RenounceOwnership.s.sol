// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IOwnable {
    function owner() external view returns (address);
    function renounceOwnership() external;
}

interface IJACKsPools {
    function tradingEnabled() external view returns (bool);
    function vaultLocked() external view returns (bool);
}

contract RenounceOwnership is Script {
    // Base Sepolia addresses
    address constant TOKEN = 0xe7De2E9f12e9BE6230f5d836D4525EEB5A2625f2;
    address constant VAULT = 0x441e76329ec37d81d99B06342B97368460F31810;
    address constant LPVAULT = 0x7766145e659AD21C28c36E720FAC8E33C6260Be2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== OWNERSHIP RENOUNCE SCRIPT ===");
        console.log("Deployer:", deployer);
        console.log("");
        
        // Check current state
        console.log("Current Ownership:");
        address tokenOwner = IOwnable(TOKEN).owner();
        address vaultOwner = IOwnable(VAULT).owner();
        console.log("TOKEN owner:", tokenOwner);
        console.log("VAULT owner:", vaultOwner);
        console.log("");
        
        // Verify preconditions for TOKEN
        bool tradingEnabled = IJACKsPools(TOKEN).tradingEnabled();
        bool vaultLocked = IJACKsPools(TOKEN).vaultLocked();
        console.log("TOKEN tradingEnabled:", tradingEnabled);
        console.log("TOKEN vaultLocked:", vaultLocked);
        console.log("");
        
        require(tradingEnabled, "Trading must be enabled first");
        require(vaultLocked, "Vault must be locked first");
        require(tokenOwner == deployer, "Deployer is not TOKEN owner");
        require(vaultOwner == deployer, "Deployer is not VAULT owner");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Renounce VAULT ownership first (no dependencies)
        console.log("Step 1: Renouncing VAULT ownership...");
        IOwnable(VAULT).renounceOwnership();
        console.log("VAULT ownership renounced!");
        
        // 2. Renounce TOKEN ownership (this also affects LP_VAULT)
        console.log("Step 2: Renouncing TOKEN ownership...");
        IOwnable(TOKEN).renounceOwnership();
        console.log("TOKEN ownership renounced!");
        console.log("Note: LP_VAULT now has no owner (uses TOKEN.owner())");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== OWNERSHIP RENOUNCED SUCCESSFULLY ===");
        console.log("New owners (should be 0x0000...):");
        console.log("TOKEN owner:", IOwnable(TOKEN).owner());
        console.log("VAULT owner:", IOwnable(VAULT).owner());
        console.log("");
        console.log("All contracts are now AUTONOMOUS!");
        console.log("No admin control remains.");
    }
}
