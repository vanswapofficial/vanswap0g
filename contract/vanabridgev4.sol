// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract VanaBridge is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ✅ HARDCODE VANS TOKEN ADDRESS
    IERC20 public constant VANS_TOKEN = IERC20(0x82741ff5937933244eb562A4b396f8079F1de914);
    
    uint256 public bridgeFee = 0.001 ether;
    mapping(bytes32 => bool) public usedProofs;
    uint256 public totalLocked;
    uint256 public totalFeesCollected;

    event BridgedToZeroG(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromZeroG(address indexed user, uint256 amount, bytes32 proofHash);
    event FeesWithdrawn(address indexed owner, uint256 amount);

    // ✅ TANPA CONSTRUCTOR - Owner otomatis msg.sender
    // constructor() Ownable(msg.sender) {}

    function bridgeToZeroG(uint256 amount) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= 1 ether, "Minimum 1 VANS");
        require(msg.value >= bridgeFee, "Insufficient fee");

        totalFeesCollected += msg.value;

        // Lock VANS
        VANS_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        totalLocked += amount;

        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, 
            amount, 
            block.chainid, 
            block.timestamp,
            "VANA_TO_0G"
        ));

        require(!usedProofs[proofHash], "Proof already used");
        usedProofs[proofHash] = true;

        emit BridgedToZeroG(msg.sender, amount, proofHash);
        return proofHash;
    }

    function completeBridgeToVana(
        bytes32 zerogProof,
        uint256 amount, 
        address recipient
    ) external nonReentrant whenNotPaused {
        require(!usedProofs[zerogProof], "Proof already used");
        require(amount <= totalLocked, "Insufficient liquidity");
        
        usedProofs[zerogProof] = true;
        totalLocked -= amount;
        
        VANS_TOKEN.safeTransfer(recipient, amount);

        emit BridgedFromZeroG(recipient, amount, zerogProof);
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        require(amount <= totalFeesCollected, "Insufficient fees");
        require(amount <= address(this).balance, "Insufficient contract balance");
        
        totalFeesCollected -= amount;
        
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Transfer failed");
        
        emit FeesWithdrawn(owner(), amount);
    }

    function withdrawAllFees() external onlyOwner {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "No fees to withdraw");
        
        totalFeesCollected = 0;
        
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Transfer failed");
        
        emit FeesWithdrawn(owner(), amount);
    }

    function feeBalance() public view returns (uint256) {
        return totalFeesCollected;
    }

    function setBridgeFee(uint256 newFee) external onlyOwner {
        bridgeFee = newFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}