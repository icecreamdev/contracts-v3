// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./Token.sol";
import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libs/ReentrancyGuard.sol";
import './libs/AddrArrayLib.sol';
import './libs/IFarm.sol';

contract Farm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using AddrArrayLib for AddrArrayLib.Addresses;
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastDepositTime;
        uint256 rewardLockedUp;
        uint256 nextHarvestUntil;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
        uint16 taxWithdraw;
        uint16 taxWithdrawBeforeLock;
        uint256 withdrawLockPeriod;
        uint256 lock;
        uint16 depositFee;
        uint256 cake_pid;
        uint16 harvestFee;
    }

    Token public immutable token;
    address payable public devaddr;
    address payable public taxLpAddress;
    uint16 public reserveFee = 200;
    uint16 public devFee = 1500;
    uint256 totalLockedUpRewards;

    uint256 public constant MAX_PERFORMANCE_FEE = 1500; // 15%
    uint256 public constant MAX_CALL_FEE = 100; // 1%
    uint256 public performanceFee = 1500; // 15%
    uint256 public callFee = 1; // 0.01%
    // 0: stake it, 1: send to reserve address
    uint256 public harvestProcessProfitMode = 0;
    event Earn(address indexed sender, uint256 pid, uint256 balance, uint256 performanceFee, uint256 callFee);

    uint256 public tokenPerBlock;
    uint256 public bonusMultiplier = 1;

    PoolInfo[] public poolInfo;
    uint256[] public poolsList;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => AddrArrayLib.Addresses) private addressByPid;
    mapping(uint256 => uint[]) public userPoolByPid;

    mapping(address => bool) private _authorizedCaller;
    mapping(uint256 => uint256) public deposits;
    uint256 public totalAllocPoint = 0;
    uint256 public immutable startBlock;
    address payable public reserveAddress; // receive farmed asset
    address payable public taxAddress; // receive fees

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 received);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawWithTax(address indexed user, uint256 indexed pid, uint256 sent, uint256 burned);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Transfer(address indexed to, uint256 requsted, uint256 sent);
    event TokenPerBlockUpdated(uint256 tokenPerBlock);
    event UpdateEmissionSettings(address indexed from, uint256 depositAmount, uint256 endBlock);
    event UpdateMultiplier(uint256 multiplierNumber);
    event SetDev(address indexed prevDev, address indexed newDev);
    event SetTaxAddr(address indexed prevAddr, address indexed newAddr);
    event SetReserveAddr(address indexed prevAddr, address indexed newAddr);
    event SetAuthorizedCaller(address indexed caller, bool _status);
    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "pool id not exisit");
        _;
    }
    IFarm public mc;
    IERC20 public cake;

    uint256 totalProfit; // hold total asset generated by this vault

    constructor(
        Token _token,
        uint256 _startBlock,
        address _mc, address _cake
    ) public {
        token = _token;
        devaddr = msg.sender;
        taxLpAddress = msg.sender;
        reserveAddress = msg.sender;
        taxAddress = msg.sender;
        tokenPerBlock = 0.1 ether;
        startBlock = _startBlock;
        reflectSetup(_mc, _cake);
    }

    function updateTokenPerBlock(uint256 _tokenPerBlock) external onlyOwner {
        require( _tokenPerBlock <= 1 ether, "too high.");
        tokenPerBlock = _tokenPerBlock;
        emit TokenPerBlockUpdated(_tokenPerBlock);
    }

    function updateMultiplier(uint256 multiplierNumber) external onlyOwner {
        require( multiplierNumber <= 10, "too high");
        bonusMultiplier = multiplierNumber;
        emit UpdateMultiplier(multiplierNumber);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(
        uint256 _allocPoint,
        address _lpToken,
        uint16 _taxWithdraw,
        uint16 _taxWithdrawBeforeLock,
        uint256 _withdrawLockPeriod,
        uint256 _lock,
        uint16 _depositFee,
        bool _withUpdate,
        uint256 _cake_pid,
        uint16 _harvestFee
    ) external onlyOwner {
        require(_depositFee <= 1000, "err1");
        require(_taxWithdraw <= 1000, "err2");
        require(_taxWithdrawBeforeLock <= 2500, "err3");
        require(_withdrawLockPeriod <= 30 days, "err4");
        IERC20(_lpToken).balanceOf( address(this) );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
        block.number > startBlock ? block.number : startBlock;

        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo(
            {
            lpToken : IERC20(_lpToken),
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accTokenPerShare : 0,
            taxWithdraw : _taxWithdraw,
            taxWithdrawBeforeLock : _taxWithdrawBeforeLock,
            withdrawLockPeriod : _withdrawLockPeriod,
            lock : _lock,
            depositFee : _depositFee,
            cake_pid : _cake_pid,
            harvestFee: _harvestFee
            })
        );

        poolsList.push(poolInfo.length);

        if (_cake_pid > 0) {
            require(_lpToken == getLpOf(_cake_pid), "src/lp!=dst/lp");
            IERC20(_lpToken).safeApprove(address(mc), 0);
            IERC20(_lpToken).safeApprove(address(mc), uint256(- 1));
        }

    }
    function set_locks(uint256 _pid,
        uint16 _taxWithdraw,
        uint16 _taxWithdrawBeforeLock,
        uint256 _withdrawLockPeriod,
        uint256 _lock,
        uint16 _depositFee,
        uint16 _harvestFee) external onlyOwner validatePoolByPid(_pid) {
        require(_depositFee <= 1000, "err1");
        require(_taxWithdraw <= 1000, "err2");
        require(_taxWithdrawBeforeLock <= 2500, "err3");
        require(_withdrawLockPeriod <= 30 days, "err4");
        poolInfo[_pid].taxWithdraw = _taxWithdraw;
        poolInfo[_pid].taxWithdrawBeforeLock = _taxWithdrawBeforeLock;
        poolInfo[_pid].withdrawLockPeriod = _withdrawLockPeriod;
        poolInfo[_pid].lock = _lock;
        poolInfo[_pid].depositFee = _depositFee;
        poolInfo[_pid].harvestFee = _harvestFee;
    }
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint256 _cake_pid
    ) external onlyOwner validatePoolByPid(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(
                _allocPoint
            );
        }
        IERC20 lp = poolInfo[_pid].lpToken;
        if (_cake_pid > 0 && poolInfo[_pid].cake_pid == 0) {
            require(address(lp) == getLpOf(_cake_pid), "src/lp!=dst/lp");
            lp.safeApprove(address(mc), 0);
            lp.safeApprove(address(mc), uint256(- 1));
            mc.deposit(_cake_pid,  lp.balanceOf(address(this)) );
        } else if (_cake_pid == 0 && poolInfo[_pid].cake_pid > 0) {
            uint256 amount = balanceOf(_pid);
            if (amount > 0)
                mc.withdraw(poolInfo[_pid].cake_pid, amount);
            lp.safeApprove(address(mc), 0);
        }
        poolInfo[_pid].cake_pid = _cake_pid;
    }

    function getMultiplier(uint256 _from, uint256 _to)
    public
    view
    returns (uint256)
    {
        return _to.sub(_from).mul(bonusMultiplier);
    }

    function pendingReward(uint256 _pid, address _user)
    public
    view
    validatePoolByPid(_pid)
    returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = deposits[_pid];
        uint256 tokenPendingReward;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accTokenPerShare = accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }
        tokenPendingReward = user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
        return tokenPendingReward.add(user.rewardLockedUp);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
        harvestAll();
    }

    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = deposits[_pid];
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        uint256 fee = tokenReward.mul(reserveFee).div(10000); // 2%
        token.mintUnlockedToken(devaddr, fee);
        token.mintLockedToken(address(this), tokenReward);
        pool.accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }
    function deposit(uint256 _pid, uint256 _amount) external {
        depositFor(msg.sender, _pid, _amount);
    }
    function depositFor(address recipient, uint256 _pid, uint256 _amount)
    public validatePoolByPid(_pid) nonReentrant notContract notBlacklisted {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][recipient];
        updatePool(_pid);
        _payRewardByPid(_pid, recipient);
        if (_amount > 0) {
            if (pool.depositFee > 0) {
                uint256 tax = _amount.mul(pool.depositFee).div(10000);
                uint256 received = _amount.sub(tax);
                pool.lpToken.safeTransferFrom(address(msg.sender), taxAddress, tax);
                uint256 oldBalance = pool.lpToken.balanceOf(address(this));
                pool.lpToken.safeTransferFrom(address(msg.sender), address(this), received);
                uint256 newBalance = pool.lpToken.balanceOf(address(this));
                received = newBalance.sub(oldBalance);
                deposits[_pid] = deposits[_pid].add(received);
                user.amount = user.amount.add(received);
                userPool(_pid, recipient);
                emit Deposit(recipient, _pid, _amount, received);
                if (pool.cake_pid > 0){
                    mc.deposit(pool.cake_pid, received);
                }
            } else {
                uint256 oldBalance = pool.lpToken.balanceOf(address(this));
                pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
                uint256 newBalance = pool.lpToken.balanceOf(address(this));
                _amount = newBalance.sub(oldBalance);
                deposits[_pid] = deposits[_pid].add(_amount);
                user.amount = user.amount.add(_amount);
                userPool(_pid, recipient);
                emit Deposit(recipient, _pid, _amount);
                if (pool.cake_pid > 0){
                    mc.deposit(pool.cake_pid, _amount);
                }
            }
            user.lastDepositTime = block.timestamp;
            if( user.nextHarvestUntil == 0 && pool.lock > 0 ){
                user.nextHarvestUntil = block.timestamp.add(pool.lock);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        _harvestAll();
    }


    event withdrawTax( uint256 tax );
    function withdraw(uint256 _pid, uint256 _amount) external validatePoolByPid(_pid)
    nonReentrant notContract {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount >= _amount && pool.cake_pid > 0 ) {
            mc.withdraw(pool.cake_pid, _amount);
        }
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        _payRewardByPid(_pid, msg.sender);
        if (_amount > 0) {
            if (pool.withdrawLockPeriod > 0 ) {
                uint256 tax = 0;
                if(block.timestamp < user.lastDepositTime + pool.withdrawLockPeriod) {
                    if( pool.taxWithdrawBeforeLock > 0 ){
                        tax = _amount.mul(pool.taxWithdrawBeforeLock).div(10000);
                    }
                }else{
                    if( pool.taxWithdraw > 0 ){
                        tax = _amount.mul(pool.taxWithdraw).div(10000);
                    }
                }
                if( tax > 0 ){
                    deposits[_pid] = deposits[_pid].sub(tax);
                    user.amount = user.amount.sub(tax);
                    _amount = _amount.sub(tax);
                    pool.lpToken.safeTransfer(taxLpAddress, tax );
                    emit withdrawTax(tax);
                }
            }
            _withdraw(_pid, _amount);
        }
        _harvestAll();
    }

    function _withdraw( uint256 _pid, uint256 _amount ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        deposits[_pid] = deposits[_pid].sub(_amount);
        user.amount = user.amount.sub(_amount);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
    }

    function emergencyWithdraw(uint256 _pid) external validatePoolByPid(_pid) nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        reflectEmergencyWithdraw(_pid, user.amount);
        deposits[_pid] = deposits[_pid].sub(user.amount);
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        deposits[_pid] = deposits[_pid].sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        userPool(_pid, msg.sender);
    }

    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 balance = token.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > balance) {
            transferSuccess = token.transfer(_to, balance);
        } else {
            transferSuccess = token.transfer(_to, _amount);
        }
        emit Transfer(_to, _amount, balance);
        require(transferSuccess, "SAFE TOKEN TRANSFER FAILED");
    }

    function setMultiplier(uint256 val) external onlyAdmin {
        bonusMultiplier = val;
    }
    function dev(address payable _devaddr) external onlyAdmin {
        emit SetDev(devaddr, _devaddr);
        devaddr = _devaddr;
    }
    function setReserveFee(uint16 val) external onlyAdmin {
        reserveFee = val;
    }
    function setDevFee(uint16 val) external onlyAdmin {
        devFee = val;
    }

    function adminSetReserveAddr(address payable _addr) external onlyAdmin {
        emit SetReserveAddr(reserveAddress, _addr);
        reserveAddress = _addr;
    }

    function adminSetTaxLpAddress(address payable _addr) external onlyAdmin {
        taxLpAddress = _addr;
    }

    function adminSetTaxAddr(address payable _addr) external onlyAdmin {
        emit SetTaxAddr(taxAddress, _addr);
        taxAddress = _addr;
    }

    function getTotalPoolUsers(uint256 _pid) external virtual view returns (uint256) {
        return addressByPid[_pid].getAllAddresses().length;
    }

    function getAllPoolUsers(uint256 _pid) public virtual view returns (address[] memory) {
        return addressByPid[_pid].getAllAddresses();
    }

    function userPoolBalances(uint256 _pid) external virtual view returns (UserInfo[] memory) {
        address[] memory list = getAllPoolUsers(_pid);
        UserInfo[] memory balances = new UserInfo[](list.length);
        for (uint i = 0; i < list.length; i++) {
            address addr = list[i];
            balances[i] = userInfo[_pid][addr];
        }
        return balances;
    }

    function userPool(uint256 _pid, address _user) internal {
        AddrArrayLib.Addresses storage addresses = addressByPid[_pid];
        uint256 amount = userInfo[_pid][_user].amount;
        if (amount > 0) {
            addresses.pushAddress(_user);
        } else if (amount == 0) {
            addresses.removeAddress(_user);
        }
    }

    function reflectSetup(address _mc, address _cake) internal {
        mc = IFarm(_mc);
        cake = IERC20(_cake);
        cake.safeApprove(_mc, 0);
        cake.safeApprove(_mc, uint256(- 1));
    }

    function setPerformanceFee(uint256 _performanceFee) external onlyAdmin {
        require(_performanceFee <= MAX_PERFORMANCE_FEE, "performanceFee cannot be more than MAX_PERFORMANCE_FEE");
        performanceFee = _performanceFee;
    }

    function setCallFee(uint256 _callFee) external onlyAdmin {
        require(_callFee <= MAX_CALL_FEE, "callFee cannot be more than MAX_CALL_FEE");
        callFee = _callFee;
    }

    function setHarvestProcessProfitMode(uint16 mode) external onlyAdmin {
        harvestProcessProfitMode = mode;
    }

    function getLpOf(uint256 pid) public view returns (address) {
        (address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accCakePerShare) = mc.poolInfo(pid);
        return lpToken;
    }
    function balanceOf(uint256 pid) public view returns (uint256) {
        (uint256 amount,) = mc.userInfo(pid, address(this));
        return amount;
    }

    function pendingCake(uint256 pid) public view returns (uint256) {
        return mc.pendingCake(pid, address(this));

    }

    function calculateHarvestRewards(uint256 pid) external view returns (uint256) {
        return pendingCake(pid).mul(callFee).div(10000);
    }

    mapping(address => bool) public contractAllowed;
    mapping(address => bool) public blacklist;
    modifier notContract() {
        if (contractAllowed[msg.sender] == false) {
            require(!_isContract(msg.sender), "CnA");
            require(msg.sender == tx.origin, "PCnA");
        }
        _;
    }
    modifier notBlacklisted() {
        require(blacklist[msg.sender] == false, "BLK");
        _;
    }
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function setContractAllowed(bool status) external onlyAdmin {
        contractAllowed[msg.sender] = status;
    }

    function setBlaclisted(address addr, bool status) external onlyAdmin {
        blacklist[addr] = status;
    }

    function reflectHarvest(uint256 pid) internal {
        if( balanceOf(pid) == 0 || pid == 0 ){
            return;
        }
        mc.deposit(pid, 0);
        harvestProcessProfit(pid);
    }

    event EnterStaking(uint256 amount);
    event TransferToReserve(address to, uint256 amount);
    function harvestProcessProfit( uint256 pid) internal{
        uint256 balance = cake.balanceOf(address(this));
        totalProfit = totalProfit.add(balance);
        if( balance > 0 ){
            uint256 currentPerformanceFee = balance.mul(performanceFee).div(10000);
            uint256 currentCallFee = balance.mul(callFee).div(10000);
            cake.safeTransfer(devaddr, currentPerformanceFee);
            cake.safeTransfer(msg.sender, currentCallFee);
            uint256 reserveAmount = cake.balanceOf(address(this));
            emit Earn(msg.sender, pid, balance, currentPerformanceFee, currentCallFee);
            if( reserveAmount > 0 ){
                if( harvestProcessProfitMode == 0 ){
                    mc.enterStaking(reserveAmount);
                    emit EnterStaking(reserveAmount);
                }else{
                    cake.safeTransfer(reserveAddress, reserveAmount);
                    emit TransferToReserve(reserveAddress, reserveAmount);
                }
            }
        }
    }

    function adminProcessReserve() external onlyAdmin {
        uint256 reserveAmount = balanceOf(0);
        if( reserveAmount > 0 ){
            mc.leaveStaking(reserveAmount);
            cake.safeTransfer(reserveAddress, reserveAmount);
        }
    }

    function harvestAll() public nonReentrant {
        _harvestAll();
    }

    function _harvestAll() internal {
        for (uint256 i = 0; i < poolsList.length; ++i) {
            uint256 pid = poolsList[i];
            if( pid == 0 ){
                continue;
            }
            reflectHarvest(pid);
        }
    }

    function inCaseTokensGetStuck(address _token, address to) external onlyAdmin {
        require(_token != address(cake), "!cake");
        require(_token != address(token), "!token");
        for (uint256 i = 0; i < poolsList.length; ++i) {
            uint256 pid = poolsList[i];
            require(address(poolInfo[pid].lpToken) != _token, "!pool asset");
        }
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
    }
    function reflectEmergencyWithdraw(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.cake_pid == 0) return;
        mc.withdraw(pool.cake_pid, _amount);
    }
    function adminEmergencyWithdraw(uint256 _pid) external onlyAdmin {
        mc.emergencyWithdraw(poolInfo[_pid].cake_pid);
    }
    function panicAll() external onlyAdmin {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            panic(pid);
        }
    }
    function panic( uint256 pid) public onlyAdmin {
        PoolInfo storage pool = poolInfo[pid];
        if( pool.cake_pid != 0 ){
            mc.emergencyWithdraw(pool.cake_pid);
            pool.lpToken.safeApprove(address(mc), 0);
            pool.cake_pid = 0;
        }
    }
    modifier onlyAdmin() {
        // does not manipulate user funds and allow fast actions to stop/panic withdraw
        require(msg.sender == owner() || msg.sender == devaddr, "access denied");
        _;
    }


    function payAllReward() public {
        for (uint256 i = 0; i < poolsList.length; ++i) {
            uint256 pid = poolsList[i];
            _payRewardByPid(pid, msg.sender);
        }
        _harvestAll();
    }
    function payRewardByPid( uint256 pid ) public {
        _payRewardByPid(pid, msg.sender);
        _harvestAll();
    }

    function canHarvest(uint256 pid, address recipient ) public view returns(bool){
        // PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][recipient];
        // return pool.lock == 0 || block.timestamp >= user.lastDepositTime + pool.lock;
        return block.timestamp >= user.nextHarvestUntil;
    }
    function _payRewardByPid( uint256 pid, address recipient ) public {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][recipient];
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if ( canHarvest(pid, recipient) ) {
            uint256 totalRewards = pending.add(user.rewardLockedUp);
            if (totalRewards > 0) {
                uint256 fee = 0;
                if(pool.harvestFee > 0){
                    fee = totalRewards.mul(pool.harvestFee).div(10000);
                    safeTokenTransfer(taxAddress, fee);
                }
                safeTokenTransfer(recipient, totalRewards.sub(fee));
                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.lock);
            }
        }else{
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
        }
        // emit PayReward(recipient, pid, status, user.amount, pending, user.rewardDebt);
    }

}
