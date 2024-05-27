// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Base64} from "solady/src/utils/Base64.sol";
import {DecimalString} from "./DecimalString.sol";
import {ERC721} from "solady/src/tokens/ERC721.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";

// Created by @sammybauch
// In collaboration with @backseats_eth

interface IBasePaint is IERC1155 {
    // Gets the current price to mint an open edition from BasePaint
    function openEditionPrice() external view returns (uint256);

    // Mints N tokens from BasePaint for a given day
    function mint(uint256 day, uint256 count) external payable;

    // Returns the current day
    function today() external view returns (uint256);
}

interface IBasePaintAPIProxy {
    function imageURL(uint256 day) external view returns (string memory);
}

contract BasePaintBot is Ownable, ERC721 {
    /// Libraries

    using LibString for uint256;
    using LibString for uint160;
    using LibString for uint96;
    using LibString for uint8;

    /// Events

    event BalanceLessThanRequired(
        uint160 indexed _address, uint96 indexed _actualBalance, uint256 indexed _expectedBalance
    );

    event FeeUpdated(uint256 indexed newFeeBasisPoints);

    event MintSkippedBalance(uint160 indexed _address, uint96 indexed _balance, uint8 indexed _amountToMint);

    event MintSkippedDaily(uint160 indexed _address, uint96 indexed _balance, uint16 indexed _lastMinted);

    event Subscribed(address indexed subscriber, address indexed mintTo, uint96 indexed balance, uint8 mintPerDay);

    event SubscriptionExtended(address indexed subscriber);

    /// Errors

    error CantBeZero();
    error MustSendETH();
    error NoBalance();
    error NotEnoughMinted();
    error NotMinter();
    error NotYourSub();
    error OwnerSendFailed();
    error RefundFailed();
    error SubAlreadyExists();
    error SubDoesntExist();
    error SubNonTransferrable();
    error TenPercentMaxFee();
    error WrongAmount();

    /// Storage

    // The address of the BasePaint contract on the Base network
    IBasePaint public basepaint;

    // The address of the owner controlled wallet with ability to mint
    address public minter;

    // A 10% fee added into the mint price
    uint256 public feeBasisPoints = 1000;

    // The amount, if any, withdrawable by the project creators
    uint256 public withdrawable;

    // Base URL for BasePaint artwork API
    string public basepaintApiBase = "https://basepaint.xyz/api/art/image?day=";

    // If BasePaint changes their metadata API, we can deploy a new contract to
    // ensure Subscription NFTs still return tokenURI with the correct image
    IBasePaintAPIProxy public basepaintApiProxy;

    // A two-slot struct with the parameters for a Subscription
    struct Subscription {
        // The address the subscription mints to.
        // Could be a hardware wallet, the same address as the owner, or a gift
        uint160 mintToAddress;
        // The balance of the subscription
        uint96 balance;
        // How many tokens to mint per day (max 255)
        uint8 mintPerDay;
        // The last day we minted for this subscription
        uint16 lastMinted;
        // The address that created the subscription
        uint160 owner;
    }

    // A mapping of address of the creator of the  Subscription to the Subscription struct
    mapping(address => Subscription) public subscriptions;

    /// Constructor

    constructor(address _basepaint, address _minter) ERC721() {
        _initializeOwner(msg.sender);
        basepaint = IBasePaint(_basepaint);
        minter = _minter;
    }

    /// Functions

    /// @notice Creates a new subscription to BasePaintBot
    /// @param _mintPerDay The number to mint per day, max 255
    /// @param _mintToAddress The address to mint to, could be the same or different from
    /// @param _length The amount of days to subscribe for
    function subscribe(uint8 _mintPerDay, address _mintToAddress, uint256 _length) external payable {
        uint256 value = msg.value;
        if (value == 0) revert MustSendETH();
        if (_mintPerDay == 0) revert CantBeZero();

        address sender = msg.sender;

        // Price per mint
        uint256 price = basepaint.openEditionPrice();
        // Per per mint * how many to mint daily * how many days
        uint256 subtotal = price * _mintPerDay * _length;
        uint256 fee = (subtotal * feeBasisPoints) / 10_000;
        if (value != (subtotal + fee)) revert WrongAmount();

        // Check if a Subscription already exists.
        // If you need to top up an existing Subscription,
        // use the `receive` function
        Subscription storage sub = subscriptions[sender];
        if (sub.mintToAddress != 0) revert SubAlreadyExists();

        uint96 balance = uint96(value);
        uint160 mintTo = _mintToAddress == address(0) ? uint160(sender) : uint160(_mintToAddress);

        sub.mintToAddress = mintTo;
        sub.balance = balance;
        sub.mintPerDay = _mintPerDay;
        sub.lastMinted = 0;
        sub.owner = uint160(sender);

        _mint(sender, this.packTokenId(sender, uint96(basepaint.today())));

        emit Subscribed(sender, _mintToAddress, balance, _mintPerDay);
    }

    /// @notice Remove the Subscription from the mapping
    /// @param _tokenId The tokenId of the subscription to remove
    function unsubscribe(uint256 _tokenId) external {
        Subscription storage subscription = subscriptions[msg.sender];

        if (ERC721(this).ownerOf(_tokenId) != msg.sender) revert NotYourSub();
        if (subscription.balance == 0) revert NoBalance();

        uint256 refund = subscription.balance;
        address subOwner = address(subscription.owner);

        // Deletes the mapping, zeroing out all data including the balance
        delete subscriptions[msg.sender];

        _burn(_tokenId);

        // Returns the funds to the owner
        (bool success,) = payable(address(subOwner)).call{value: refund}("");
        if (!success) revert RefundFailed();
    }

    /// @dev Called by the owner's wallet/backend via a cron job to mint and distribute
    /// @param _addresses The subscription addressess to look up and mint to (only sent in if they have a balance)
    /// @param _toMint The number of tokens to mint (fetched offchain to save gas)
    function mintDaily(address[] calldata _addresses, uint256 _toMint) external {
        if (msg.sender != minter) revert NotMinter();

        uint256 today = basepaint.today() - 1;

        uint256 mintCost = basepaint.openEditionPrice();
        uint256 fee = (mintCost * feeBasisPoints) / 10_000;
        uint256 priceWithFee = mintCost + fee;

        // mint outside the loop to save gas, contract will hold
        // and disburse to subscribers in the loop
        basepaint.mint{value: mintCost * _toMint}(today, _toMint);

        uint256 minted;
        for (uint256 i; i < _addresses.length;) {
            Subscription storage subscription = subscriptions[_addresses[i]];

            // Handle 0 balance
            if (subscription.balance == 0) {
                emit MintSkippedBalance(subscription.owner, subscription.balance, subscription.mintPerDay);

                unchecked {
                    ++i;
                }
                continue;
            }

            uint48 count = subscription.mintPerDay;
            uint256 totalSpend = priceWithFee * count;

            // Handle not enough of a balance
            if (subscription.balance < totalSpend) {
                emit BalanceLessThanRequired(subscription.owner, subscription.balance, totalSpend);

                unchecked {
                    ++i;
                }
                continue;
            }

            // Skip if we've already minted for them today
            if (subscription.lastMinted == today) {
                emit MintSkippedDaily(subscription.owner, subscription.balance, subscription.lastMinted);

                unchecked {
                    ++i;
                }
                continue;
            }

            // Update Subscription attributes and storage vars
            subscription.lastMinted = uint16(today);
            subscription.balance -= uint96(totalSpend);
            withdrawable += fee * count;

            // Transfer the NFT to the subscriber's mintToAddress
            basepaint.safeTransferFrom(address(this), address(subscription.mintToAddress), today, count, "");

            unchecked {
                minted += count;
                ++i;
            }
        }

        // Sanity check worth the extra gas spend
        // Check the logs emitted and re-run the cron job without the bad address(es)
        if (minted != _toMint) revert NotEnoughMinted();
    }

    /// @dev Only callable by the owner of the contract, changes the basis points
    /// @param _newFeeBasisPoints The new fee basis points (e.g. 1000 = a 10% fee)
    function adjustFeeBasisPoints(uint256 _newFeeBasisPoints) external onlyOwner {
        if (_newFeeBasisPoints > 1000) revert TenPercentMaxFee();
        feeBasisPoints = _newFeeBasisPoints;
        emit FeeUpdated(_newFeeBasisPoints);
    }

    /// @dev Only callable by the owner of the contract, changes the minter address
    /// @param _newMinter The new minter address who can call the mintDaily  function
    function setNewMinter(address _newMinter) external onlyOwner {
        minter = _newMinter;
    }

    /// @dev Only callable by the owner of the contract, sets a contract responsible for
    /// returning the correct image URL for a given day
    /// @notice If BasePaint changes their metadata API, we can deploy a new contract to
    /// ensure Subscription NFTs still return tokenURI with the correct image
    /// @param _newProxyAddress The new minter address who can call the mintDaily  function
    function setNewBasepaintAPIProxy(address _newProxyAddress) external onlyOwner {
        basepaintApiProxy = IBasePaintAPIProxy(_newProxyAddress);
    }

    /// @dev Only callable by the owner of the contract, changes the base URI for BasePaint art
    /// @param _newBaseURI The new base URI to be concatenated with the subscription token ID
    function setNewBasepaintAPIBase(string calldata _newBaseURI) external onlyOwner {
        basepaintApiBase = _newBaseURI;
    }

    /// @dev Callable by anyone. Distributes withdrawable funds to the project creators
    function withdraw() external {
        uint256 toWithdraw = withdrawable;
        withdrawable = 0;

        (bool success,) = owner().call{value: toWithdraw}("");
        if (!success) revert OwnerSendFailed();
    }

    /// @notice Add funds to your subscription
    receive() external payable {
        Subscription storage subscription = subscriptions[msg.sender];
        if (subscription.owner == 0) revert SubDoesntExist();
        subscription.balance += uint96(msg.value);
        emit SubscriptionExtended(msg.sender);
    }

    /// ERC-721

    /// @dev Returns the tokenURI for a given subscription NFT, where the image is the
    /// BasePaint art for the day the subscription was created alongside onchain metadata
    /// for the subscription
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        (address owner, uint96 day) = this.unpackTokenId(tokenId);

        Subscription memory subscription = subscriptions[owner];
        if (subscription.owner == 0) revert SubDoesntExist();

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"BasePaintBot Subscription", "description":"Daily automints of the BasePaint NFT", "image": "',
                            _imageUrl(day),
                            '", "attributes": [{"trait_type": "balance", "value": "',
                            subscription.balance > 0
                                ? DecimalString._decimalString(subscription.balance, 18, false)
                                : "0",
                            ' ETH" }, {"trait_type": "mint per day", "value": ',
                            subscription.mintPerDay.toString(),
                            '}, {"trait_type": "recipient", "value": "',
                            subscription.mintToAddress.toHexString(),
                            '"}, {"trait_type": "subscriber since", "value": "BasePaint Day #',
                            day.toString(),
                            '"}]}'
                        )
                    )
                )
            )
        );
    }

    function _imageUrl(uint256 day) internal view returns (string memory) {
        if (address(basepaintApiProxy) != address(0)) {
            return basepaintApiProxy.imageURL(day);
        }
        return string(abi.encodePacked(basepaintApiBase, day.toString()));
    }

    function name() public pure override returns (string memory) {
        return "BasePaintBot Subscription";
    }

    function symbol() public pure override returns (string memory) {
        return "BPBS";
    }

    /// @dev Token is "soulbound" to the subscription owner
    /// Allows minting (transfer from 0 address) and burning (transfer to 0 address)
    /// but reverts on transfers to/from any other address
    /// @notice Subscriptions support specifying a different address to receive mints
    function _beforeTokenTransfer(address from, address to, uint256) internal pure override {
        if (from == address(0)) return;
        if (to == address(0)) return;

        revert SubNonTransferrable();
    }

    function packTokenId(address _addr, uint96 _num) external pure returns (uint256) {
        return (uint256(uint160(_addr)) << 96) | _num;
    }

    function unpackTokenId(uint256 tokenID) external pure returns (address, uint96) {
        address addr = address(uint160(tokenID >> 96));
        uint96 num = uint96(tokenID);
        return (addr, num);
    }

    /// Boilerplate

    // Boilerplate and receive ERC-1155 tokens in this contract
    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    // Boilerplate and receive ERC-721 tokens in this contract
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        virtual
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
