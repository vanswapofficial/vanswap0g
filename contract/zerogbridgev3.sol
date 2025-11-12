// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ZeroGBridge is ERC20, ReentrancyGuard, Ownable, Pausable {
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
        
        // ✅ FIXED: MANUAL SIGNATURE VERIFICATION
        bytes32 messageHash = keccak256(abi.encodePacked(
            vanaProof, 
            amount, 
            recipient,
            block.chainid,
            "VANA_TO_ZEROG"
        ));
        
        // ✅ FIXED: Manual Ethereum signed message hash
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        
        // ✅ FIXED: Manual signature recovery
        address recoveredSigner = recoverSigner(ethSignedMessageHash, signature);
        require(recoveredSigner == verifier, "Invalid signature");

        usedProofs[vanaProof] = true;
        totalMinted += amount;
        _mint(recipient, amount);

        emit BridgedFromVana(recipient, amount, vanaProof);
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyBurn(address account, uint256 amount) external onlyOwner {
        require(paused(), "Only when paused");
        _burn(account, amount);
    }
}