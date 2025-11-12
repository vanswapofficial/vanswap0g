// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract ZeroGBridge is ERC20, ReentrancyGuard, Ownable, Pausable {
    using ECDSA for bytes32;
    
    uint256 public constant MAX_SUPPLY = 48_000_000 * 10**18;
    
    address public verifier; 
    mapping(bytes32 => bool) public usedProofs;
    uint256 public totalMinted;

    event BridgedToVana(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromVana(address indexed user, uint256 amount, bytes32 proofHash);

    constructor() ERC20("Wrapped VANS", "wVANS") Ownable(msg.sender) {}

    // ✅ BURN wVANS → UNLOCK VANS (0G → VANA)
    function bridgeToVana(uint256 amount) external nonReentrant whenNotPaused returns (bytes32) {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        _burn(msg.sender, amount);

        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, 
            amount, 
            block.chainid, 
            block.timestamp, 
            "ZEROG_TO_VANA"
        ));

        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;

        emit BridgedToVana(msg.sender, amount, proofHash);
        return proofHash;
    }

    // ✅ MINT wVANS ← LOCK VANS (VANA → 0G) 
    function bridgeFromVana(
        bytes32 vanaProof,  // Proof dari VanaBridge
        uint256 amount, 
        address recipient,
        bytes memory signature
    ) external nonReentrant whenNotPaused {
        require(!usedProofs[vanaProof], "Proof already used");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds supply");
        
        // ✅ VERIFY: Signature untuk Vana proof
        bytes32 messageHash = keccak256(abi.encodePacked(
            vanaProof, 
            amount, 
            recipient,
            block.chainid,
            "VANA_TO_ZEROG"
        ));
        
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedMessageHash.recover(signature);
        
        require(recoveredSigner == verifier, "Invalid signature");

        usedProofs[vanaProof] = true;
        totalMinted += amount;
        _mint(recipient, amount);

        emit BridgedFromVana(recipient, amount, vanaProof);
    }

    function setVerifier(address _verifier) external onlyOwner {
        verifier = _verifier;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}