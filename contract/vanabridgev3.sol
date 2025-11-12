// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract VanaBridge is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public constant VANS_TOKEN = IERC20(0x82741ff5937933244eb562A4b396f8079F1de914);
    
    address public verifier; 
    uint256 public bridgeFee = 0.001 ether;
    uint256 public minBridgeAmount = 1 ether;
    uint256 public maxBridgeAmount = 100000 ether;
    uint256 public totalLocked;

    mapping(bytes32 => bool) public usedProofs;

    event BridgedToZeroG(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromZeroG(address indexed user, uint256 amount, bytes32 proofHash);

    constructor() Ownable(msg.sender) {}

    // ✅ LOCK VANS → MINT wVANS (VANA → 0G)
    function bridgeToZeroG(uint256 amount) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= minBridgeAmount && amount <= maxBridgeAmount, "Invalid amount");
        require(msg.value >= bridgeFee, "Insufficient fee");

        uint256 balanceBefore = VANS_TOKEN.balanceOf(address(this));
        VANS_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = VANS_TOKEN.balanceOf(address(this));
        require(balanceAfter - balanceBefore == amount, "Token transfer failed");

        totalLocked += amount;

        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, 
            amount, 
            block.chainid, 
            block.timestamp, 
            "VANA_TO_ZEROG"
        ));

        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;

        emit BridgedToZeroG(msg.sender, amount, proofHash);
        return proofHash;
    }

    // ✅ UNLOCK VANS ← BURN wVANS (0G → VANA)
    function bridgeFromZeroG(
        bytes32 zerogProof,  // Proof dari ZeroGBridge
        uint256 amount, 
        address recipient,
        bytes memory signature
    ) external nonReentrant whenNotPaused {
        require(!usedProofs[zerogProof], "Proof already used");
        require(amount <= totalLocked, "Insufficient liquidity");
        
        // ✅ FIXED: MANUAL SIGNATURE VERIFICATION
        bytes32 messageHash = keccak256(abi.encodePacked(
            zerogProof, 
            amount, 
            recipient,
            block.chainid, 
            "ZEROG_TO_VANA"
        ));
        
        // ✅ FIXED: Manual Ethereum signed message hash
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        
        // ✅ FIXED: Manual signature recovery
        address recoveredSigner = recoverSigner(ethSignedMessageHash, signature);
        require(recoveredSigner == verifier, "Invalid signature");

        usedProofs[zerogProof] = true;
        totalLocked -= amount;
        VANS_TOKEN.safeTransfer(recipient, amount);

        emit BridgedFromZeroG(recipient, amount, zerogProof);
    }

    // ✅ FIXED: MANUAL SIGNATURE RECOVERY (Tanpa OZ v5)
    function recoverSigner(bytes32 ethSignedMessageHash, bytes memory signature) 
        internal pure returns (address) 
    {
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from signature
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // Handle v values (27 or 28)
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, "Invalid signature version");

        // Recover signer address
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        require(signer != address(0), "Invalid signature");

        return signer;
    }

    function setVerifier(address _verifier) external onlyOwner {
        verifier = _verifier;
    }

    function setBridgeFee(uint256 newFee) external onlyOwner {
        bridgeFee = newFee;
    }

    function setBridgeLimits(uint256 min, uint256 max) external onlyOwner {
        require(min < max, "Invalid limits");
        minBridgeAmount = min;
        maxBridgeAmount = max;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawVANS(uint256 amount) external onlyOwner {
        require(paused(), "Only when paused");
        VANS_TOKEN.safeTransfer(owner(), amount);
        totalLocked -= amount;
    }

    receive() external payable {}
}