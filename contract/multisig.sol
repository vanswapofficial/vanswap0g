// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title LindurzMultiSigWallet
 * @dev Kontrak dompet multisig dengan fitur keamanan terbaru dan peningkatan keamanan
 * @notice Versi yang ditingkatkan dari kontrak multisig asli dengan proteksi keamanan modern
 */
contract LindurzMultiSigWallet is ReentrancyGuard {
    // Constants
    uint256 public constant MAX_OWNER_COUNT = 50;
    uint256 public constant CONFIRMATION_TIMEOUT = 7 days;

    // Events dengan parameter yang lebih informatif
    event Confirmation(address indexed sender, uint256 indexed transactionId);
    event Revocation(address indexed sender, uint256 indexed transactionId);
    event Submission(uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event ExecutionFailure(uint256 indexed transactionId, bytes reason);
    event Deposit(address indexed sender, uint256 value);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event RequirementChange(uint256 required);
    event TransactionExpired(uint256 indexed transactionId);

    // Struct yang diperbarui dengan timestamp
    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
        uint256 submissionTime;
        uint256 confirmationCount;
    }

    // State variables
    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;
    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public required;
    uint256 public transactionCount;
    
    // Tambahan state variables untuk keamanan
    mapping(uint256 => uint256) public confirmationTimestamps;
    bool public initialized;

    // Modifiers modern dengan error messages
    modifier onlyWallet() {
        require(msg.sender == address(this), "Caller is not the wallet");
        _;
    }

    modifier ownerDoesNotExist(address owner) {
        require(!isOwner[owner], "Owner already exists");
        _;
    }

    modifier ownerExists(address owner) {
        require(isOwner[owner], "Owner does not exist");
        _;
    }

    modifier transactionExists(uint256 transactionId) {
        require(transactionId < transactionCount && transactions[transactionId].destination != address(0), 
                "Transaction does not exist");
        _;
    }

    modifier confirmed(uint256 transactionId, address owner) {
        require(confirmations[transactionId][owner], "Transaction not confirmed by owner");
        _;
    }

    modifier notConfirmed(uint256 transactionId, address owner) {
        require(!confirmations[transactionId][owner], "Transaction already confirmed");
        _;
    }

    modifier notExecuted(uint256 transactionId) {
        require(!transactions[transactionId].executed, "Transaction already executed");
        _;
    }

    modifier notNull(address _address) {
        require(_address != address(0), "Address cannot be zero");
        _;
    }

    modifier validRequirement(uint256 ownerCount, uint256 _required) {
        require(ownerCount <= MAX_OWNER_COUNT, "Too many owners");
        require(_required <= ownerCount && _required > 0 && ownerCount > 0, 
                "Invalid requirement parameters");
        _;
    }

    modifier notExpired(uint256 transactionId) {
        require(
            block.timestamp <= transactions[transactionId].submissionTime + CONFIRMATION_TIMEOUT,
            "Transaction expired"
        );
        _;
    }

    /**
     * @dev Fallback function - Menerima ETH
     */
    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    /**
     * @dev Contract constructor sets initial owners and required number of confirmations
     * @param _owners List of initial owners
     * @param _required Number of required confirmations
     */
    constructor(address[] memory _owners, uint256 _required) 
        validRequirement(_owners.length, _required) 
    {
        for (uint256 i = 0; i < _owners.length; i++) {
            require(!isOwner[_owners[i]] && _owners[i] != address(0), "Invalid owner");
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        required = _required;
        initialized = true;
    }

    /**
     * @dev Allows to add a new owner
     * @param owner Address of new owner
     */
    function addOwner(address owner)
        public
        onlyWallet
        ownerDoesNotExist(owner)
        notNull(owner)
        validRequirement(owners.length + 1, required)
    {
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }

    /**
     * @dev Allows to remove an owner
     * @param owner Address of owner to remove
     */
    function removeOwner(address owner)
        public
        onlyWallet
        ownerExists(owner)
    {
        isOwner[owner] = false;
        
        // Remove owner from array dengan cara yang lebih aman
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        if (required > owners.length) {
            changeRequirement(owners.length);
        }
        emit OwnerRemoval(owner);
    }

    /**
     * @dev Allows to replace an owner with a new owner
     * @param owner Address of owner to be replaced
     * @param newOwner Address of new owner
     */
    function replaceOwner(address owner, address newOwner)
        public
        onlyWallet
        ownerExists(owner)
        ownerDoesNotExist(newOwner)
        notNull(newOwner)
    {
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }
        isOwner[owner] = false;
        isOwner[newOwner] = true;
        emit OwnerRemoval(owner);
        emit OwnerAddition(newOwner);
    }

    /**
     * @dev Allows to change the number of required confirmations
     * @param _required Number of required confirmations
     */
    function changeRequirement(uint256 _required)
        public
        onlyWallet
        validRequirement(owners.length, _required)
    {
        required = _required;
        emit RequirementChange(_required);
    }

    /**
     * @dev Allows an owner to submit and confirm a transaction
     * @param destination Transaction target address
     * @param value Transaction ether value
     * @param data Transaction data payload
     * @return transactionId Returns transaction ID
     */
    function submitTransaction(address destination, uint256 value, bytes memory data)
        public
        ownerExists(msg.sender)
        notNull(destination)
        returns (uint256 transactionId)
    {
        transactionId = addTransaction(destination, value, data);
        confirmTransaction(transactionId);
    }

    /**
     * @dev Allows an owner to confirm a transaction
     * @param transactionId Transaction ID
     */
    function confirmTransaction(uint256 transactionId)
        public
        ownerExists(msg.sender)
        transactionExists(transactionId)
        notConfirmed(transactionId, msg.sender)
        notExecuted(transactionId)
        notExpired(transactionId)
    {
        confirmations[transactionId][msg.sender] = true;
        transactions[transactionId].confirmationCount++;
        emit Confirmation(msg.sender, transactionId);
        
        // Auto-execute jika konfirmasi cukup
        if (isConfirmed(transactionId)) {
            executeTransaction(transactionId);
        }
    }

    /**
     * @dev Allows an owner to revoke a confirmation for a transaction
     * @param transactionId Transaction ID
     */
    function revokeConfirmation(uint256 transactionId)
        public
        ownerExists(msg.sender)
        confirmed(transactionId, msg.sender)
        notExecuted(transactionId)
    {
        confirmations[transactionId][msg.sender] = false;
        transactions[transactionId].confirmationCount--;
        emit Revocation(msg.sender, transactionId);
    }

    /**
     * @dev Allows anyone to execute a confirmed transaction dengan proteksi reentrancy
     * @param transactionId Transaction ID
     */
    function executeTransaction(uint256 transactionId)
        public
        nonReentrant
        transactionExists(transactionId)
        notExecuted(transactionId)
        notExpired(transactionId)
    {
        require(isConfirmed(transactionId), "Transaction not confirmed");
        
        Transaction storage txn = transactions[transactionId];
        txn.executed = true;

        (bool success, bytes memory reason) = txn.destination.call{value: txn.value}(txn.data);
        
        if (success) {
            emit Execution(transactionId);
        } else {
            txn.executed = false;
            emit ExecutionFailure(transactionId, reason);
        }
    }

    /**
     * @dev Clean up expired transactions
     * @param transactionId Transaction ID to check
     */
    function cleanupExpiredTransaction(uint256 transactionId)
        public
        transactionExists(transactionId)
        notExecuted(transactionId)
    {
        require(
            block.timestamp > transactions[transactionId].submissionTime + CONFIRMATION_TIMEOUT,
            "Transaction not expired"
        );
        
        emit TransactionExpired(transactionId);
        // Reset confirmations untuk transaksi yang expired
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmations[transactionId][owners[i]]) {
                confirmations[transactionId][owners[i]] = false;
            }
        }
        transactions[transactionId].confirmationCount = 0;
    }

    /**
     * @dev Returns the confirmation status of a transaction
     * @param transactionId Transaction ID
     * @return bool Confirmation status
     */
    function isConfirmed(uint256 transactionId) 
        public 
        view 
        returns (bool) 
    {
        return transactions[transactionId].confirmationCount >= required;
    }

    /**
     * @dev Adds a new transaction to the transaction mapping
     * @param destination Transaction target address
     * @param value Transaction ether value
     * @param data Transaction data payload
     * @return transactionId Returns transaction ID
     */
    function addTransaction(address destination, uint256 value, bytes memory data)
        internal
        returns (uint256 transactionId)
    {
        transactionId = transactionCount;
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false,
            submissionTime: block.timestamp,
            confirmationCount: 0
        });
        transactionCount++;
        emit Submission(transactionId);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @dev Returns number of confirmations of a transaction
     * @param transactionId Transaction ID
     * @return count Number of confirmations
     */
    function getConfirmationCount(uint256 transactionId)
        public
        view
        returns (uint256 count)
    {
        return transactions[transactionId].confirmationCount;
    }

    /**
     * @dev Returns total number of transactions after filters are applied
     * @param pending Include pending transactions
     * @param executed Include executed transactions
     * @return count Total number of transactions after filters are applied
     */
    function getTransactionCount(bool pending, bool executed)
        public
        view
        returns (uint256 count)
    {
        for (uint256 i = 0; i < transactionCount; i++) {
            if ((pending && !transactions[i].executed) || (executed && transactions[i].executed)) {
                count++;
            }
        }
    }

    /**
     * @dev Returns list of owners
     * @return List of owner addresses
     */
    function getOwners()
        public
        view
        returns (address[] memory)
    {
        return owners;
    }

    /**
     * @dev Returns array with owner addresses which confirmed transaction
     * @param transactionId Transaction ID
     * @return _confirmations Array of owner addresses
     */
    function getConfirmations(uint256 transactionId)
        public
        view
        returns (address[] memory _confirmations)
    {
        address[] memory confirmationsTemp = new address[](owners.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmations[transactionId][owners[i]]) {
                confirmationsTemp[count] = owners[i];
                count++;
            }
        }
        
        _confirmations = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            _confirmations[i] = confirmationsTemp[i];
        }
    }

    /**
     * @dev Returns list of transaction IDs in defined range
     * @param from Index start position of transaction array
     * @param to Index end position of transaction array
     * @param pending Include pending transactions
     * @param executed Include executed transactions
     * @return _transactionIds Array of transaction IDs
     */
    function getTransactionIds(uint256 from, uint256 to, bool pending, bool executed)
        public
        view
        returns (uint256[] memory _transactionIds)
    {
        uint256[] memory transactionIdsTemp = new uint256[](transactionCount);
        uint256 count = 0;
        
        for (uint256 i = 0; i < transactionCount; i++) {
            if ((pending && !transactions[i].executed) || (executed && transactions[i].executed)) {
                transactionIdsTemp[count] = i;
                count++;
            }
        }
        
        require(from <= to && to <= count, "Invalid range");
        _transactionIds = new uint256[](to - from);
        
        for (uint256 i = from; i < to; i++) {
            _transactionIds[i - from] = transactionIdsTemp[i];
        }
    }

    /**
     * @dev Returns transaction details
     * @param transactionId Transaction ID
     * @return Transaction details
     */
    function getTransaction(uint256 transactionId)
        public
        view
        returns (Transaction memory)
    {
        return transactions[transactionId];
    }

    /**
     * @dev Check if transaction is expired
     * @param transactionId Transaction ID
     * @return bool True if expired
     */
    function isExpired(uint256 transactionId) public view returns (bool) {
        return block.timestamp > transactions[transactionId].submissionTime + CONFIRMATION_TIMEOUT;
    }

    /**
     * @dev Get contract ETH balance
     * @return Contract balance
     */
    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }
}