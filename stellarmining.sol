// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract StellarMining is ReentrancyGuard {
    IERC20 public stlrToken;
    address public owner;

    // DECIMAL CONFIGURATION: 8 decimals
    uint256 public constant DECIMALS = 8;
    uint256 public constant DECIMAL_FACTOR = 10**DECIMALS;
    
    // Mining Config (adjusted for 8 decimals)
    uint256 public constant BASE_RATE = 100000; // 0.0001 STLR (8 decimals) per second
    uint256 public constant REFERRAL_BOOST = 50000; // 0.00005 STLR per second
    uint256 public constant MAX_REFERRALS = 50;
    uint256 public constant MAX_SESSION = 6 hours; 
    uint256 public constant MIN_WITHDRAW = 100 * DECIMAL_FACTOR; // 100 STLR (8 decimals)
    uint256 public constant INVITE_REWARD = 10 * DECIMAL_FACTOR; // 10 STLR for new invitee

    uint256 public totalUsers;

    struct Miner {
        uint256 lastClaimTime;
        uint256 referralCount;
        address referrer;
        uint256 balance;
        bool hasReceivedInviteReward;
    }
    mapping(address => Miner) public miners;
    mapping(string => address) public referralCodes;
    mapping(address => string) public userToReferralCode;

    // Staking Config (8 decimals)
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 apy;
        bool withdrawn;
    }
    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => uint256) public durationToApy;

    uint256 public minStake = 10 * DECIMAL_FACTOR; // 10 STLR
    uint256 public maxStake = 1000 * DECIMAL_FACTOR; // 1000 STLR

    event Mined(address indexed user, uint256 amount);
    event WithdrawnMining(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ApyUpdated(uint256 duration, uint256 newApy);
    event NativeReceived(address sender, uint256 amount);
    event Registered(address indexed user, string code);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Contracts not allowed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _stlrToken) {
        stlrToken = IERC20(_stlrToken);
        owner = msg.sender;

        // APY in percentage (85% = 85)
        durationToApy[1] = 85;   // 1 Month -> 85%
        durationToApy[3] = 150;  // 3 Months -> 150%
        durationToApy[6] = 250;  // 6 Months -> 250%
        durationToApy[12] = 600; // 12 Months -> 600%
    }

    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    function withdrawNative() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No native coin");
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    function setApy(uint256 durationMonths, uint256 newApy) external onlyOwner {
        durationToApy[durationMonths] = newApy;
        emit ApyUpdated(durationMonths, newApy);
    }

    // --- Mining Logic ---

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function autoRegister() external onlyEOA nonReentrant {
        require(bytes(userToReferralCode[msg.sender]).length == 0, "Already registered");

        totalUsers++;
        
        // Generate referral code: STLR + number (padded with 0 if < 10)
        string memory suffix = _toString(totalUsers);
        string memory code;
        if (totalUsers < 10) {
            code = string(abi.encodePacked("STLR0", suffix));
        } else {
            code = string(abi.encodePacked("STLR", suffix));
        }

        referralCodes[code] = msg.sender;
        userToReferralCode[msg.sender] = code;

        emit Registered(msg.sender, code);
    }

    function setReferrer(string memory code) external onlyEOA nonReentrant {
        address ref = referralCodes[code];
        require(ref != address(0) && ref != msg.sender, "Invalid referrer");
        require(miners[msg.sender].referrer == address(0), "Already has referrer");

        miners[msg.sender].referrer = ref;

        // Boost referrer
        if (miners[ref].referralCount < MAX_REFERRALS) {
            miners[ref].referralCount++;
        }

        // Reward Invitee (10 STLR)
        if (!miners[msg.sender].hasReceivedInviteReward) {
            miners[msg.sender].hasReceivedInviteReward = true;
            require(stlrToken.balanceOf(address(this)) >= INVITE_REWARD, "Contract empty for reward");
            stlrToken.transfer(msg.sender, INVITE_REWARD);
        }
    }

    function claimMiningRewards() external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        uint256 currentTime = block.timestamp;

        // Start mining if not started
        if (m.lastClaimTime == 0) {
            m.lastClaimTime = currentTime;
            return;
        }

        // Check if 6 hours have passed
        uint256 timeElapsed = currentTime - m.lastClaimTime;
        require(timeElapsed >= MAX_SESSION, "Mining in progress");

        // Calculate reward for 6 hours
        uint256 effectiveTime = MAX_SESSION;
        uint256 rate = BASE_RATE + (m.referralCount * REFERRAL_BOOST);
        uint256 reward = effectiveTime * rate;

        // Add to balance (8 decimals)
        m.balance += reward;
        m.lastClaimTime = currentTime;

        emit Mined(msg.sender, reward);
    }

    function withdrawMining(uint256 amount) external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        require(m.balance >= amount, "Insufficient balance");
        require(amount >= MIN_WITHDRAW, "Below min withdraw");
        require(stlrToken.balanceOf(address(this)) >= amount, "Contract empty");

        m.balance -= amount;
        require(stlrToken.transfer(msg.sender, amount), "Transfer failed");

        emit WithdrawnMining(msg.sender, amount);
    }

    function getPendingReward(address user) external view returns (uint256) {
        Miner memory m = miners[user];
        if (m.lastClaimTime == 0) return 0;

        uint256 timeElapsed = block.timestamp - m.lastClaimTime;
        if (timeElapsed > MAX_SESSION) {
            timeElapsed = MAX_SESSION;
        }

        uint256 rate = BASE_RATE + (m.referralCount * REFERRAL_BOOST);
        return timeElapsed * rate;
    }

    // --- Staking Logic (8 decimals) ---

    function stake(uint256 amount, uint256 durationMonths) external onlyEOA nonReentrant {
        require(amount >= minStake && amount <= maxStake, "Invalid amount");
        uint256 apy = durationToApy[durationMonths];
        require(apy > 0, "Invalid duration");

        uint256 durationSec = durationMonths * 30 days;

        require(stlrToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        userStakes[msg.sender].push(Stake({
            amount: amount,
            startTime: block.timestamp,
            duration: durationSec,
            apy: apy,
            withdrawn: false
        }));

        emit Staked(msg.sender, amount, durationSec);
    }

    function withdrawStake(uint256 index) external onlyEOA nonReentrant {
        require(index < userStakes[msg.sender].length, "Invalid index");
        Stake storage s = userStakes[msg.sender][index];
        require(!s.withdrawn, "Already withdrawn");
        require(block.timestamp >= s.startTime + s.duration, "Locked");

        s.withdrawn = true;

        // Calculate reward with 8 decimal precision
        uint256 reward = (s.amount * s.apy * s.duration) / (100 * 365 days);
        uint256 total = s.amount + reward;

        require(stlrToken.balanceOf(address(this)) >= total, "Contract empty");
        require(stlrToken.transfer(msg.sender, total), "Transfer failed");

        emit Unstaked(msg.sender, s.amount, reward);
    }

    // --- Utility Functions ---
    
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }
    
    function getStakeCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }
    
    function getMinerInfo(address user) external view returns (
        uint256 lastClaimTime,
        uint256 referralCount,
        address referrer,
        uint256 balance,
        bool hasReceivedInviteReward
    ) {
        Miner memory m = miners[user];
        return (m.lastClaimTime, m.referralCount, m.referrer, m.balance, m.hasReceivedInviteReward);
    }
}