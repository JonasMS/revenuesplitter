// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IRevenueSplitter.sol";

contract RevenueSplitter is ERC20 {
    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the revenue period timestamp used by the contract
    bytes32 private constant REVENUE_PERIOD_DATE_TYPEHASH = keccak256("LastPeriod(uint256 date)");

    uint256 public constant REVENUE_PERIOD_DURATION = 30 days;
    uint256 public constant BLACKOUT_PERIOD_DURATION = 3 days;

    struct RestrictedTokenGrant {
        uint256 vestingDate;
        uint256 amount;
        bool exercised;
    }

    address public owner;
    uint256 public maxTokenSupply;

    mapping(address => RestrictedTokenGrant[]) private _tokenGrants;
    uint256 private _totalSupplyUnexercised;

    uint256 public curPeriodId;

    uint256 private curPeriodDate;
    uint256 private curPeriodRevenue;

    uint256 private lastPeriodDate;
    uint256 private lastPeriodRevenue;

    // @dev maps revenuePeriodId's to user addresses to the amount of ETH they've withdrawn in the given period
    mapping(uint256 => mapping(address => uint256)) private withdrawalReceipts;

    constructor(
        address owner_,
        uint256 maxTokenSupply_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        owner = owner_;
        maxTokenSupply = maxTokenSupply_;
        uint256 initialPeriodDate = block.timestamp + REVENUE_PERIOD_DURATION;
        curPeriodDate = initialPeriodDate;

        emit StartNewPeriod(0, initialPeriodDate, 0);
    }

    function balanceOfUnexercised(address account_) public view virtual returns (uint256 balanceUnexercised) {
        RestrictedTokenGrant[] storage tokenGrants = _tokenGrants[account_];
        for (uint256 i = 0; i < tokenGrants.length; i++) {
            if (!tokenGrants[i].exercised) {
                balanceUnexercised += tokenGrants[i].amount;
            }
        }
    }

    function _isBlackoutPeriod() internal view returns (bool) {
        uint256 curPeriodStartTime = curPeriodDate - REVENUE_PERIOD_DURATION;
        return BLACKOUT_PERIOD_DURATION >= block.timestamp - curPeriodStartTime;
    }

    function _mintRestricted(
        address account_,
        uint256 amount_,
        uint256 vestingDate_
    ) internal {
        require(account_ != address(0), "RevenueSplitter::_mintRestricted: MINT_TO_ZERO_ADDRESS");

        _beforeTokenGrantTransfer(address(0), account_, amount_, vestingDate_);

        _totalSupplyUnexercised += amount_;
        _tokenGrants[account_].push(RestrictedTokenGrant(vestingDate_, amount_, false));

        emit MintRestricted(account_, amount_);

        _afterTokenGrantTransfer(address(0), account_, amount_, vestingDate_);
    }

    // _deposit(address account_, uint amount_) internal virtual
    //  - require deposit amount less than max supply
    //  - calculates amount to mint
    //  - handles transaction fee
    //
    //  - mints or a grant token
    //  - emits event
    function _deposit(address account_, uint256 amount_) internal virtual {
        require(
            totalSupply() + _totalSupplyUnexercised + amount_ <= maxTokenSupply,
            "RevenueSplitter::_deposit: MAX_TOKEN_LIMIT"
        );

        // mint tokens if in first period
        // otherwise, grant restricted tokens
        if (lastPeriodDate == 0) {
            _mint(account_, amount_);
        } else {
            _mintRestricted(account_, amount_, curPeriodId + 2);
        }

        emit Deposit(account_, amount_);
    }

    function deposit() external payable virtual {
        _deposit(msg.sender, msg.value);
    }

    function _getWithdrawalPower(address account_) internal view returns (uint256 amount) {
        amount = balanceOf(account_) - withdrawalReceipts[curPeriodId - 1][account_];
    }

    function _withdraw(address account_) internal virtual {
        require(!_isBlackoutPeriod(), "RevenueSplitter::_withdraw: BLACKOUT_PERIOD");
        require(lastPeriodRevenue > 0, "RevenueSplitter::_withdraw: ZERO_REVENUE");

        uint256 withdrawalPower = _getWithdrawalPower(account_);

        require(withdrawalPower > 0, "RevenueSplitter::_withdraw: ZERO_WITHDRAWAL_POWER");

        uint256 ethShare = (withdrawalPower * lastPeriodRevenue) / totalSupply();

        withdrawalReceipts[curPeriodId - 1][account_] += withdrawalPower;
        (bool success, bytes memory returnData) = account_.call{ value: ethShare }("");
        if (success) {
            emit Withdraw(account_, ethShare);
        } else if (returnData.length > 0) {
            // From OZ's Address.sol contract
            assembly {
                let returndata_size := mload(returnData)
                revert(add(32, returnData), returndata_size)
            }
        } else {
            revert("RevenuePool::_withdraw: CALL_REVERTED_WITHOUT_MESSAGE");
        }
    }

    function withdraw() external virtual {
        _withdraw(msg.sender);
    }

    function withdrawBySig(
        uint256 revenuePeriodDate_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external {
        require(revenuePeriodDate_ == lastPeriodDate, "RevenueSplitter::withdrawBySig: INVALID_REVENUE_PERIOD_DATE");

        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), _getChainId(), address(this))
        );
        bytes32 structHash = keccak256(abi.encode(REVENUE_PERIOD_DATE_TYPEHASH, revenuePeriodDate_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = ecrecover(digest, v_, r_, s_);

        require(signer != address(0), "RevenueSplitter::withdrawBySig: INVALID_SIGNATURE");

        _withdraw(signer);
    }

    function withdrawBulk(
        uint256[] calldata datesList_,
        uint8[] calldata vList_,
        bytes32[] calldata rList_,
        bytes32[] calldata sList_
    ) external {
        require(datesList_.length == vList_.length, "RevenueSplitter::withdrawBulk: INFORMATION_ARITY_MISMATCH_V_LIST");
        require(datesList_.length == rList_.length, "RevenueSplitter::withdrawBulk: INFORMATION_ARITY_MISMATCH_R_LIST");
        require(datesList_.length == sList_.length, "RevenueSplitter::withdrawBulk: INFORMATION_ARITY_MISMATCH_S_LIST");

        for (uint256 i = 0; i < vList_.length; i++) {
            address(this).call(
                abi.encodeWithSignature(
                    "withdrawBySig(uint256,uint8,bytes32,bytes32)",
                    datesList_[i],
                    vList_[i],
                    rList_[i],
                    sList_[i]
                )
            );
        }
    }

    function _redeem(address account_) internal virtual {
        RestrictedTokenGrant[] storage tokenGrants = _tokenGrants[account_];

        require(tokenGrants.length > 0, "RevenueSplitter::redeem: ZERO_TOKEN_GRANTS");

        uint256 exercisedTokensCount;
        for (uint256 i = 0; i < tokenGrants.length; i++) {
            if (tokenGrants[i].vestingDate <= curPeriodId && !tokenGrants[i].exercised) {
                tokenGrants[i].exercised = true;
                exercisedTokensCount += tokenGrants[i].amount;
            }
        }

        require(exercisedTokensCount > 0, "RevenueSplitter::redeem: ZERO_EXERCISABLE_SHARES");

        _totalSupplyUnexercised -= exercisedTokensCount;
        _mint(account_, exercisedTokensCount);

        emit Redeem(account_, exercisedTokensCount);
    }

    function redeem() external virtual {
        _redeem(msg.sender);
    }

    function redeemBySig(
        uint256 revenuePeriodDate_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external {
        require(revenuePeriodDate_ == lastPeriodDate, "RevenueSplitter::redeemBySig: INVALID_REVENUE_PERIOD_DATE");

        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), _getChainId(), address(this))
        );
        bytes32 structHash = keccak256(abi.encode(REVENUE_PERIOD_DATE_TYPEHASH, revenuePeriodDate_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = ecrecover(digest, v_, r_, s_);

        require(signer != address(0), "RevenueSplitter::redeemBySig: INVALID_SIGNATURE");

        _redeem(signer);
    }

    function redeemBulk(
        uint256[] calldata datesList_,
        uint8[] calldata vList_,
        bytes32[] calldata rList_,
        bytes32[] calldata sList_
    ) external {
        require(datesList_.length == vList_.length, "RevenueSplitter::redeemBulk: INFORMATION_ARITY_MISMATCH_V_LIST");
        require(datesList_.length == rList_.length, "RevenueSplitter::redeemBulk: INFORMATION_ARITY_MISMATCH_R_LIST");
        require(datesList_.length == sList_.length, "RevenueSplitter::redeemBulk: INFORMATION_ARITY_MISMATCH_S_LIST");

        for (uint256 i = 0; i < vList_.length; i++) {
            address(this).call(
                abi.encodeWithSignature(
                    "redeemBySig(uint256,uint8,bytes32,bytes32)",
                    datesList_[i],
                    vList_[i],
                    rList_[i],
                    sList_[i]
                )
            );
        }
    }

    function _setCurPeriod(uint256 date_, uint256 revenue_) internal {
        curPeriodDate = date_;
        curPeriodRevenue = revenue_;
    }

    function _setLastPeriod(uint256 date_, uint256 revenue_) internal {
        lastPeriodDate = date_;
        lastPeriodRevenue = revenue_;
    }

    function startNewPeriod() external {
        require(block.timestamp >= curPeriodDate, "RevenueSplitter::startNewPeriod: REVENUE_PERIOD_IN_PROGRESS");

        // Prevent setting `lastPeriodRevenue` to an amount greater than the contract owns
        uint256 endingPeriodRevenue = curPeriodRevenue > address(this).balance
            ? address(this).balance
            : curPeriodRevenue;
        uint256 startingPeriodDate = block.timestamp + REVENUE_PERIOD_DURATION;
        uint256 startingPeriodId = curPeriodId + 1;

        _beforeStartNewPeriod(startingPeriodId, startingPeriodDate, endingPeriodRevenue);

        _setLastPeriod(curPeriodDate, endingPeriodRevenue);

        _setCurPeriod(startingPeriodDate, endingPeriodRevenue);

        curPeriodId = startingPeriodId;

        emit StartNewPeriod(startingPeriodId, startingPeriodDate, endingPeriodRevenue);

        _afterStartNewPeriod(startingPeriodId, startingPeriodDate, endingPeriodRevenue);
    }

    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external virtual {
        require(msg.sender == owner, "RevenuePool::execute: ONLY_OWNER");

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory returnData) = targets[i].call{ value: values[i] }(calldatas[i]);
            if (success) {
                emit Execute(targets[i], values[i], calldatas[i]);
            } else if (returnData.length > 0) {
                // From OZ's Address.sol contract
                assembly {
                    let returndata_size := mload(returnData)
                    revert(add(32, returnData), returndata_size)
                }
            } else {
                revert("RevenuePool::execute: CALL_REVERTED_WITHOUT_MESSAGE");
            }
        }
    }

    receive() external payable {
        _onReceive(msg.value, curPeriodRevenue, curPeriodDate);
        curPeriodRevenue += msg.value;
        emit PaymentReceived(msg.sender, msg.value);
    }

    /* OVERRIDES */
    // Prevent tokens from being used for a withdrawal more than once per revenue period
    // by transfering withdrawal receipts from the transfer sender to the recipient.
    function _transfer(
        address to_,
        address from_,
        uint256 amount_
    ) internal virtual override {
        uint256 fromWithdrawnReceipts = withdrawalReceipts[curPeriodId - 1][from_];

        // 0 < withdrawalReceiptTransfer < amount_
        uint256 withdrawalReceiptTransfer = fromWithdrawnReceipts >= amount_ ? amount_ : fromWithdrawnReceipts;

        withdrawalReceipts[curPeriodId - 1][to_] += withdrawalReceiptTransfer;
        withdrawalReceipts[curPeriodId - 1][from_] -= withdrawalReceiptTransfer;

        super._transfer(from_, to_, amount_);
    }

    /* SETTERS */
    function setMaxTokenSupply(uint256 maxTokenSupply_) external virtual {
        require(msg.sender == owner, "RevenuePool::setMaxTokenSupply: ONLY_OWNER");
        maxTokenSupply = maxTokenSupply_;
    }

    /* UTILS */
    function _getChainId() internal view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    /* HOOKS */
    function _beforeTokenGrantTransfer(
        address from_,
        address to_,
        uint256 amount_,
        uint256 vestingDate_
    ) internal virtual {}

    function _afterTokenGrantTransfer(
        address from_,
        address to_,
        uint256 amount_,
        uint256 vestingDate_
    ) internal virtual {}

    function _beforeStartNewPeriod(
        uint256 startingPeriodId_,
        uint256 startingPeriodDate_,
        uint256 endingPeriodRevenue_
    ) internal virtual {}

    function _afterStartNewPeriod(
        uint256 startingPeriodId_,
        uint256 startingPeriodDate_,
        uint256 endingPeriodRevenue_
    ) internal virtual {}

    function _onReceive(
        uint256 amount_,
        uint256 periodRevenue,
        uint256 periodDate
    ) internal virtual {}

    /* EVENTS */
    event Deposit(address indexed account, uint256 amount);

    event Withdraw(address indexed account, uint256 amount);

    event MintRestricted(address indexed account, uint256 amount);

    event Redeem(address indexed account, uint256);

    event StartNewPeriod(uint256 indexed periodId, uint256 periodEndDate, uint256 periodRevenue);

    event Execute(address indexed target, uint256 value, bytes);

    event PaymentReceived(address, uint256);
}
