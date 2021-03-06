pragma solidity ^0.4.23;

import "./ClockAuctionBase.sol";
import "./interfaces/IMysteriousTreasure.sol";

contract ClockAuction is ClockAuctionBase {

    modifier isHuman() {
        require (msg.sender == tx.origin, "robot is not permitted");
        _;
    }


    ///////////////////////
    // Constructor
    ///////////////////////

    /// @dev Constructor creates a reference to the NFT ownership contract
    ///  and verifies the owner cut is in the valid range.
    /// @param _nftAddress - address of a deployed contract implementing
    ///  the Nonfungible Interface.
    ///  _cut - percent cut the owner takes on each auction, must be
    ///  between 0-10,000. It can be considered as transaction fee.
    ///  bidWaitingMinutes - biggest waiting time from a bid's starting to ending(in minutes)
    constructor(
        address _nftAddress,
        address _pangu,
        ISettingsRegistry _registry
        )
    public {
        ERC721Basic candidateContract = ERC721Basic(_nftAddress);
        // InterfaceId_ERC721 = 0x80ac58cd;
        // require(candidateContract.supportsInterface(0x80ac58cd));

        nonFungibleContract = candidateContract;
        registry = _registry;

        RING = ERC20(registry.addressOf(SettingIds.CONTRACT_RING_ERC20_TOKEN));
        // NOTE: to make auction work well
        // set address of bancorExchange in registry first
        _setPangu(_pangu);


    }

    ///////////////////////
    // Auction Create and Cancel
    ///////////////////////

    function createAuction(
        uint256 _tokenId,
        uint256 _startingPriceInToken,
        uint256 _endingPriceInToken,
        uint256 _duration,
        uint256 _startAt,
        address _token)
    public
    canBeStoredWith64Bits(_startAt) {

        require(msg.sender == pangu, "only pangu can call this");

        require(_startingPriceInToken <= 1000000000 * 10 ** 18 && _endingPriceInToken <= 1000000000 * 10**18);
        require(_duration <= 100 days);
        // pangu can only set its own as seller
        _createAuction(msg.sender, _tokenId, _startingPriceInToken, _endingPriceInToken, _duration, _startAt, msg.sender, _token);
    }

    /// @dev Cancels an auction that hasn't been won yet.
    ///  Returns the NFT to original owner.
    /// @notice This is a state-modifying function that can
    ///  be called while the contract is paused.
    /// @param _tokenId - ID of token on auction
    function cancelAuction(uint256 _tokenId)
    public
    {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));

        address seller = auction.seller;
        require((msg.sender == seller && !paused) || msg.sender == owner);
        
        // once someone has bidden for this auction, no one has the right to cancel it.
        require(auction.lastBidder == 0x0);
        _cancelAuction(_tokenId,seller);
    }

    //@dev only NFT contract can invoke this
    //@param _from - owner of _tokenId
    function receiveApproval(
        address _from,
        uint256 _tokenId,
        bytes //_extraData
    )
    public
    whenNotPaused
    {
        if (msg.sender == address(nonFungibleContract)) {
            uint256 startingPriceInRING;
            uint256 endingPriceInRING;
            uint256 duration;
            address seller;

            assembly {
                let ptr := mload(0x40)
                calldatacopy(ptr, 0, calldatasize)
                startingPriceInRING := mload(add(ptr,132))
                endingPriceInRING := mload(add(ptr,164))
                duration := mload(add(ptr,196))
                seller := mload(add(ptr,228))
            }
            require(startingPriceInRING <= 1000000000 * 10 ** 18 && endingPriceInRING <= 1000000000 * 10**18);
            require(duration <= 1000 days);
            uint startAt = now;
            //TODO: add parameter _token
            _createAuction(_from, _tokenId, startingPriceInRING, endingPriceInRING, duration, startAt, seller, address(RING));
        }

    }

    ///////////////////////
    // Bid With Auction
    ///////////////////////

    /// @dev Bids on an open auction, completing the auction and transferring
    ///  ownership of the NFT if enough Ether is supplied.
    /// @param _tokenId - ID of token to bid on.
    /// @dev bid with eth(in wei). Computes the price and transfers winnings.
    /// Does NOT transfer ownership of token.
    function bidWithETH(uint256 _tokenId, address _referer)
    public
    payable
    whenNotPaused
    isHuman
    returns (uint256)
    {
        require(msg.value > 0);
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];
        // can only bid the auction that allows ring
        require(auction.token == address(RING));

        // Explicitly check that this auction is currently live.
        // (Because of how Ethereum mappings work, we can't just count
        // on the lookup above failing. An invalid _tokenId will just
        // return an auction object that is all zeros.)
        require(_isOnAuction(auction));

        // Check that the incoming bid is higher than the current
        // price
        uint256 priceInRING = _currentPriceInToken(auction);
        // assure msg.value larger than current price in ring
        // priceInRING represents minimum return
        // if return is smaller than priceInRING
        // it will be reverted in bancorprotocol
        // so dont worry
        IBancorExchange bancorExchange = IBancorExchange(registry.addressOf(AuctionSettingIds.CONTRACT_BANCOR_EXCHANGE));
        uint256 ringFromETH = bancorExchange.buyRING.value(msg.value)(priceInRING);


        uint refund = ringFromETH - priceInRING;
        if (refund > 0) {
            // if there is surplus RING
            // then give it back to the msg.sender
            RING.transfer(msg.sender, refund);
        }

        IClaimBountyCalculator claimBountyCalculator = IClaimBountyCalculator(registry.addressOf(AuctionSettingIds.CONTRACT_AUCTION_CLAIM_BOUNTY));
        uint claimBounty = claimBountyCalculator.tokenAmountForBounty(auction.token);
        uint bidMoment = _buyProcess(msg.sender, auction, priceInRING, _referer, claimBounty);

        // Tell the world!
        // 0x0 refers to ETH
        // NOTE: priceInRING, not priceInETH
        emit NewBid(_tokenId, msg.sender, _referer, priceInRING, 0x0, bidMoment);

        return priceInRING;
    }

    // @dev bid with RING. Computes the price and transfers winnings.
    function _bidWithToken(address _from, uint256 _tokenId, uint256 _valueInToken, address _referer) internal returns (uint256){
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        // Check that the incoming bid is higher than the current price
        uint priceInToken = _currentPriceInToken(auction);
        require(_valueInToken >= priceInToken,
            "your offer is lower than the current price, try again with a higher one.");
        uint refund = _valueInToken - priceInToken;

        if (refund > 0) {
            ERC20(auction.token).transfer(_from, refund);
        }

        IClaimBountyCalculator claimBountyCalculator = IClaimBountyCalculator(registry.addressOf(AuctionSettingIds.CONTRACT_AUCTION_CLAIM_BOUNTY));
        uint claimBounty = claimBountyCalculator.tokenAmountForBounty(auction.token);

        uint bidMoment = _buyProcess(_from, auction, priceInToken, _referer, claimBounty);

        // Tell the world!
        emit NewBid(_tokenId, _from, _referer, priceInToken, auction.token, bidMoment);

        return priceInToken;
    }

    // here to handle bid for LAND(NFT) using RING
    // @dev bidder must use RING.transfer(address(this), _valueInRING, bytes32(_tokenId)
    // to invoke this function
    // @param _data - need to be generated from (tokenId + referer)

    function tokenFallback(address _from, uint256 _valueInToken, bytes _data) public whenNotPaused {
        uint tokenId;
        address referer;
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize)
            tokenId := mload(add(ptr, 132))
            referer := mload(add(ptr, 164))
        }

        Auction storage auction = tokenIdToAuction[tokenId];
        require(_isOnAuction(auction));

        if (msg.sender == auction.token) {
                _bidWithToken(_from, tokenId, _valueInToken, referer);
        }
    }

    // TODO: advice: offer some reward for the person who claimed
    // @dev claim _tokenId for auction's lastBidder
    function claimLandAsset(uint _tokenId) public isHuman {
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        require(_isOnAuction(auction));
        // at least bidWaitingTime after last bidder's bid moment,
        // and no one else has bidden during this bidWaitingTime,
        // then any one can claim this token(land) for lastBidder.
        require(auction.lastBidder != 0x0 && now >= auction.lastBidStartAt + registry.uintOf(AuctionSettingIds.UINT_AUCTION_BID_WAITING_TIME),
            "this auction has not finished yet, try again later");

        IMysteriousTreasure mysteriousTreasure = IMysteriousTreasure(registry.addressOf(AuctionSettingIds.CONTRACT_MYSTERIOUS_TREASURE));
        mysteriousTreasure.unbox(_tokenId);

        ERC20 token = ERC20(auction.token);
        address lastBidder = auction.lastBidder;
        uint lastRecord = auction.lastRecord;
        address lastReferer = auction.lastReferer;

        uint auctionCut = registry.uintOf(AuctionSettingIds.UINT_AUCTION_CUT);
        IClaimBountyCalculator claimBountyCalculator = IClaimBountyCalculator(registry.addressOf(AuctionSettingIds.CONTRACT_AUCTION_CLAIM_BOUNTY));

        uint claimBounty = claimBountyCalculator.tokenAmountForBounty(auction.token);
        // if Auction is sucessful, refererBounty is taken on by evolutionland
        uint refererBounty = computeCut(lastRecord.sub(claimBounty) / 11, auctionCut);

        //prevent re-entry attack
        _removeAuction(_tokenId);

        nonFungibleContract.safeTransferFrom(this, lastBidder, _tokenId);

        // if there is claimBounty, then reward who invoke this function
        if (claimBounty > 0) {
            require(token.transfer(msg.sender, claimBounty));
        }

        if (lastReferer != 0x0) {
            require(token.transfer(lastReferer, refererBounty));
        }

        emit AuctionSuccessful(_tokenId, lastRecord, lastBidder);
    }


    // TODO: add _token to compatible backwards with ring and eth
    function _buyProcess(address _buyer, Auction storage _auction, uint _priceInToken, address _referer, uint _claimBounty)
    internal
    canBeStoredWith128Bits(_priceInToken)
    returns (uint256){
        uint priceWithoutBounty = _priceInToken.sub(_claimBounty);

        uint auctionCut = registry.uintOf(AuctionSettingIds.UINT_AUCTION_CUT);

        // the first bid
        if (_auction.lastBidder == 0x0 && _priceInToken > 0) {
            require(now >= uint256( _auction.startedAt));
            //  Calculate the auctioneer's cut.
            // (NOTE: computeCut() is guaranteed to return a
            //  value <= price, so this subtraction can't go negative.)
            // TODO: token to the seller
            // we dont touch claimBounty
            uint256 sellerProceedsInToken = priceWithoutBounty - computeCut(priceWithoutBounty, auctionCut);

            // transfer to the seller
            ERC20(_auction.token).transfer(_auction.seller, sellerProceedsInToken);
        }

        // TODO: the math calculation needs further check
        //  not the first bid
        if (_auction.lastRecord > 0 && _auction.lastBidder != 0x0) {
            // TODO: repair bug of first bid's time limitation
            // if this the first bid, there is no time limitation
            require(now <= _auction.lastBidStartAt + registry.uintOf(AuctionSettingIds.UINT_AUCTION_BID_WAITING_TIME), "It's too late.");

            // _priceInToken that is larger than lastRecord
            // was assured in _currentPriceInRING(_auction)
            // here double check
            // 1.1*price + bounty - (price + bounty) = 0.1price
            // we dont touch claimBounty
            uint extraForEach = (_priceInToken.sub(uint256(_auction.lastRecord))) / 2;
            uint realReturn = extraForEach.sub(computeCut( extraForEach, auctionCut));
            if (_auction.lastReferer == 0x0) {
                ERC20(_auction.token).transfer(_auction.seller, realReturn);
                ERC20(_auction.token).transfer(_auction.lastBidder, (realReturn + uint256(_auction.lastRecord)));
            } else {
                ERC20(_auction.token).transfer(_auction.seller, realReturn);
                ERC20(_auction.token).transfer(_auction.lastBidder, ((9 * realReturn / 10) + uint256(_auction.lastRecord)));
                ERC20(_auction.token).transfer(_auction.lastReferer, realReturn / 10);
            }

        }

        // modify bid-related member variables
        _auction.lastBidder = _buyer;
        _auction.lastRecord = uint128(_priceInToken);
        _auction.lastBidStartAt = now;
        _auction.lastReferer = _referer;

        return _auction.lastBidStartAt;
    }


    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) public onlyOwner {
        if (_token == 0x0) {
            owner.transfer(address(this).balance);
            return;
        }
        ERC20 token = ERC20(_token);
        uint balance = token.balanceOf(address(this));
        token.transfer(owner, balance);

        emit ClaimedTokens(_token, owner, balance);
    }

        /// @dev Computes owner's cut of a sale.
    /// @param _price - Sale price of NFT.
    function computeCut(uint256 _price, uint256 _cut) public pure returns (uint256) {
        // NOTE: We don't use SafeMath (or similar) in this function because
        //  all of our entry functions carefully cap the maximum values for
        //  currency (at 128-bits), and ownerCut <= 10000 (see the require()
        //  statement in the ClockAuction constructor). The result of this
        //  function is always guaranteed to be <= _price.
        return _price * _cut / 10000;
    }

        /// @dev Returns auction info for an NFT on auction.
    /// @param _tokenId - ID of NFT on auction.
    function getAuction(uint256 _tokenId)
    public
    view
    returns
    (
        address seller,
        uint256 startingPrice,
        uint256 endingPrice,
        uint256 duration,
        uint256 startedAt,
        address token,
        uint128 lastRecord,
        address lastBidder,
        uint256 lastBidStartAt,
        address lastReferer
    ) {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        return (
        auction.seller,
        auction.startingPriceInToken,
        auction.endingPriceInToken,
        auction.duration,
        auction.startedAt,
        auction.token,
        auction.lastRecord,
        auction.lastBidder,
        auction.lastBidStartAt,
        auction.lastReferer
        );
    }

    /// @dev Returns the current price of an auction.
    /// 
    /// @param _tokenId - ID of the token price we are checking.
    function getCurrentPriceInToken(uint256 _tokenId)
    public
    view
    returns (uint256)
    {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        return _currentPriceInToken(auction);
    }

    // to apply for the safeTransferFrom
    function onERC721Received(
        address, //_operator,
        address, //_from,
        uint256, // _tokenId,
        bytes //_data
    )
    public
    returns(bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function setPangu(address _pangu) public onlyOwner {
        _setPangu(_pangu);
    }


    // get auction's price of last bidder offered
    // @dev return price of _auction (in RING)
    function getLastRecord(uint _tokenId) public view returns (uint256) {
        return tokenIdToAuction[_tokenId].lastRecord;
    }

    function getLastBidder(uint _tokenId) public view returns (address) {
        return tokenIdToAuction[_tokenId].lastBidder;
    }

    function getLastBidStartAt(uint _tokenId) public view returns (uint256) {
        return tokenIdToAuction[_tokenId].lastBidStartAt;
    }

    // @dev if someone new wants to bid, the lowest price he/she need to afford
    function computeNextBidRecord(uint _tokenId) public view returns (uint256) {
        return _currentPriceInToken(tokenIdToAuction[_tokenId]);
    }

    function updateRING() public onlyOwner {
        RING = ERC20(registry.addressOf(SettingIds.CONTRACT_RING_ERC20_TOKEN));
    }


    function transferTreasureOwnership(address _newOwner) public onlyOwner {
        IMysteriousTreasure mysteriousTreasure = IMysteriousTreasure(registry.addressOf(AuctionSettingIds.CONTRACT_MYSTERIOUS_TREASURE));
        mysteriousTreasure.transferOwnership(_newOwner);
    }

}
