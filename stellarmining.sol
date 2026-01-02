// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
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
    IERC20 public constant STLR_TOKEN = IERC20(0xDaF91D7F48E52FB79A0413Fd44b9965110664BD0);
    
    address public owner;

    uint256 public constant DECIMALS = 8;
    uint256 public constant DECIMAL_FACTOR = 10**DECIMALS;

    // Mining Config
    uint256 public constant BASE_RATE = 100000; // 0.0001 STLR per second (8 decimals)
    uint256 public constant REFERRAL_BOOST = 50000; // 0.00005 STLR per second
    uint256 public constant MAX_REFERRALS = 50;
    uint256 public constant MAX_SESSION = 6 hours;
    uint256 public constant MIN_WITHDRAW = 100 * DECIMAL_FACTOR; // 100 STLR
    uint256 public constant INVITE_REWARD = 10 * DECIMAL_FACTOR; // 10 STLR bonus

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

    // Staking Config
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 apy;
        bool withdrawn;
    }
    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => uint256) public durationToApy;

    uint256 public minStake = 10 * DECIMAL_FACTOR;
    uint256 public maxStake = 1000 * DECIMAL_FACTOR;

    event Mined(address indexed user, uint256 amount);
    event WithdrawnMining(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ApyUpdated(uint256 duration, uint256 newApy);
    event ReferrerSet(address indexed user, address indexed referrer, uint256 bonusAmount);
    event Registered(address indexed user, string code);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Contracts not allowed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        require(address(STLR_TOKEN) != address(0), "Token address is zero");

        durationToApy[1] = 85;
        durationToApy[3] = 150;
        durationToApy[6] = 250;
        durationToApy[12] = 600;
    }

    receive() external payable {
        // Accept native coins
    }

    function withdrawNative() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No native coin");
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }

    // PERBAIKAN: Bonus langsung ke mining balance, bukan ke wallet
    function setReferrer(string memory code) external onlyEOA nonReentrant {
        address ref = referralCodes[code];
        require(ref != address(0) && ref != msg.sender, "Invalid referrer");
        require(miners[msg.sender].referrer == address(0), "Already has referrer");

        miners[msg.sender].referrer = ref;

        // Boost referrer
        if (miners[ref].referralCount < MAX_REFERRALS) {
            miners[ref].referralCount++;
        }

        // PERBAIKAN: Tambah bonus ke mining balance, bukan transfer ke wallet
        if (!miners[msg.sender].hasReceivedInviteReward) {
            miners[msg.sender].hasReceivedInviteReward = true;
            
            // Tambahkan bonus ke balance mining user
            miners[msg.sender].balance += INVITE_REWARD;
            
            // Log event tanpa transfer langsung
            emit ReferrerSet(msg.sender, ref, INVITE_REWARD);
        }
    }

    function autoRegister() external onlyEOA nonReentrant {
        require(bytes(userToReferralCode[msg.sender]).length == 0, "Already registered");

        totalUsers++;

        // Generate referral code: STLR + number
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

    function claimMiningRewards() external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        uint256 currentTime = block.timestamp;

        if (m.lastClaimTime == 0) {
            m.lastClaimTime = currentTime;
            return;
        }

        uint256 timeElapsed = currentTime - m.lastClaimTime;
        require(timeElapsed >= MAX_SESSION, "Mining in progress");

        uint256 effectiveTime = MAX_SESSION;
        uint256 rate = BASE_RATE + (m.referralCount * REFERRAL_BOOST);
        uint256 reward = effectiveTime * rate;

        m.balance += reward;
        m.lastClaimTime = currentTime;

        emit Mined(msg.sender, reward);
    }

    function withdrawMining(uint256 amount) external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        require(m.balance >= amount, "Insufficient balance");
        require(amount >= MIN_WITHDRAW, "Below min withdraw");
        require(STLR_TOKEN.balanceOf(address(this)) >= amount, "Contract empty");

        m.balance -= amount;
        require(STLR_TOKEN.transfer(msg.sender, amount), "Transfer failed");

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

    function getMiningBalance(address user) external view returns (uint256) {
        return miners[user].balance;
    }

    // Staking functions...
    function stake(uint256 amount, uint256 durationMonths) external onlyEOA nonReentrant {
        require(amount >= minStake && amount <= maxStake, "Invalid amount");
        uint256 apy = durationToApy[durationMonths];
        require(apy > 0, "Invalid duration");

        uint256 durationSec = durationMonths * 30 days;

        require(STLR_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");

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

        uint256 reward = (s.amount * s.apy * s.duration) / (100 * 365 days);
        uint256 total = s.amount + reward;

        require(STLR_TOKEN.balanceOf(address(this)) >= total, "Contract empty");
        require(STLR_TOKEN.transfer(msg.sender, total), "Transfer failed");

        emit Unstaked(msg.sender, s.amount, reward);
    }

    // Utility functions...
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
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

    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }

    function getMinerInfo(address user) external view returns (
        uint256 lastClaimTime,
        uint256 referralCount,
        address referrer,
        uint256 balance,
        bool hasReceivedInviteReward,
        string memory referralCode
    ) {
        Miner memory m = miners[user];
        return (
            m.lastClaimTime,
            m.referralCount,
            m.referrer,
            m.balance,
            m.hasReceivedInviteReward,
            userToReferralCode[user]
        );
    }

    function getContractTokenBalance() external view returns (uint256) {
        return STLR_TOKEN.balanceOf(address(this));
    }

    function getTokenAddress() external pure returns (address) {
        return address(STLR_TOKEN);
    }

    function getTokenDecimals() external pure returns (uint256) {
        return DECIMALS;
    }
}