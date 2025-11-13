// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title StepByStepMultiSigWallet
 * @dev Multisig dengan setup bertahap - tambah owner dulu, lalu set required
 */
contract StepByStepMultiSigWallet {
    event OwnerAdded(address indexed owner);
    event RequirementChanged(uint256 required);
    event TransactionSubmitted(uint256 indexed txId);
    event TransactionExecuted(uint256 indexed txId);
    event DepositReceived(address indexed sender, uint256 amount);

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;
    bool public setupComplete;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not owner");
        _;
    }

    modifier setupIncomplete() {
        require(!setupComplete, "Setup already complete");
        _;
    }

    modifier setupComplete() {
        require(setupComplete, "Setup not complete");
        _;
    }

    /**
     * @dev Constructor - deployer jadi owner pertama
     */
    constructor() {
        owners.push(msg.sender);
        isOwner[msg.sender] = true;
        setupComplete = false;
    }

    /**
     * @dev Tambah owner - HANYA butuh address owner
     */
    function addOwner(address newOwner) external onlyOwner setupIncomplete {
        require(newOwner != address(0), "Invalid address");
        require(!isOwner[newOwner], "Already owner");
        
        owners.push(newOwner);
        isOwner[newOwner] = true;
        emit OwnerAdded(newOwner);
    }

    /**
     * @dev Set required confirmations - fungsi TERPISAH
     */
    function setRequired(uint256 _required) external onlyOwner setupIncomplete {
        require(_required > 0 && _required <= owners.length, "Invalid required");
        require(owners.length >= 2, "Need at least 2 owners");
        
        required = _required;
        setupComplete = true;
        emit RequirementChanged(_required);
    }

    /**
     * @dev Submit transaction
     */
    function submitTransaction(address to, uint256 value, bytes calldata data) 
        external 
        onlyOwner 
        setupComplete 
        returns (uint256) 
    {
        uint256 txId = transactions.length;
        transactions.push(Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmations: 0
        }));

        // Auto confirm by submitter
        confirmations[txId][msg.sender] = true;
        transactions[txId].confirmations++;

        emit TransactionSubmitted(txId);

        // Auto execute if enough confirmations
        if (transactions[txId].confirmations >= required) {
            _executeTransaction(txId);
        }

        return txId;
    }

    /**
     * @dev Confirm transaction
     */
    function confirmTransaction(uint256 txId) external onlyOwner setupComplete {
        require(txId < transactions.length, "Invalid tx ID");
        require(!confirmations[txId][msg.sender], "Already confirmed");
        
        Transaction storage txn = transactions[txId];
        require(!txn.executed, "Already executed");
        
        confirmations[txId][msg.sender] = true;
        txn.confirmations++;

        if (txn.confirmations >= required) {
            _executeTransaction(txId);
        }
    }

    /**
     * @dev Execute transaction internal
     */
    function _executeTransaction(uint256 txId) internal {
        Transaction storage txn = transactions[txId];
        require(!txn.executed, "Already executed");
        require(txn.confirmations >= required, "Not enough confirmations");
        
        txn.executed = true;
        
        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        require(success, "Execution failed");
        
        emit TransactionExecuted(txId);
    }

    /**
     * @dev Get owners count
     */
    function getOwnersCount() external view returns (uint256) {
        return owners.length;
    }

    /**
     * @dev Check if setup complete
     */
    function isSetupComplete() external view returns (bool) {
        return setupComplete;
    }

    receive() external payable {
        if (msg.value > 0) {
            emit DepositReceived(msg.sender, msg.value);
        }
    }
}