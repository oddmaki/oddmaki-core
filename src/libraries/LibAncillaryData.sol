// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title LibAncillaryData
 * @notice Encodes ancillary data for CTF/UMA market conditions in comma-delimited key:value format.
 *         Format: "key:value,key2:value2,..."
 *         Addresses are lowercase hex without 0x prefix; uints are decimal strings.
 */
library LibAncillaryData {
    /**
     * @notice Builds base ancillary data from title and description.
     *         Used when creating market groups where the question is assembled on-chain.
     */
    function create(string memory title, string memory description) internal pure returns (bytes memory) {
        return abi.encodePacked("title:", title, ",description:", description);
    }

    /**
     * @notice Enriches caller-supplied ancillary data with market identity fields and oracle
     *         resolution fields in a single pass.
     *         Appended fields: market_id, venue_id, initializer, res_data, ooRequester, chain_id.
     * @param ancillaryData  Base ancillary data (title/description from SDK or create()).
     * @param marketId       Allocated market identifier.
     * @param venueId        Venue identifier.
     * @param creator        Address that created the market.
     * @param oracle         Diamond proxy address (CTF oracle and OO requester via delegatecall).
     * @param chainId        Current chain ID.
     */
    function enrichAncillaryData(
        bytes memory ancillaryData,
        uint256 marketId,
        uint256 venueId,
        address creator,
        address oracle,
        uint256 chainId
    ) internal pure returns (bytes memory) {
        bytes memory result = appendKeyValueUint(ancillaryData, "market_id", marketId);
        result = appendKeyValueUint(result, "venue_id", venueId);
        result = appendKeyValueAddress(result, "initializer", creator);
        result = abi.encodePacked(result, ",res_data:p1: 0, p2: 1, p3: 0.5");
        result = appendKeyValueAddress(result, "ooRequester", oracle);
        result = appendKeyValueUint(result, "chain_id", chainId);
        return result;
    }

    /**
     * @notice Generates a stable questionId that is independent of ancillary data content.
     *         This allows placeholder markets to update their question without invalidating
     *         CTF tokens or the conditionId.
     *         Format: "oddmaki.protocol,controller:0x...,chain_id:84532,venue_id:1,market_id:54"
     * @param oracle    Diamond proxy address.
     * @param chainId   Current chain ID.
     * @param venueId   Venue identifier.
     * @param marketId  Market identifier.
     */
    function generateQuestionId(address oracle, uint256 chainId, uint256 venueId, uint256 marketId)
        internal
        pure
        returns (bytes32)
    {
        bytes memory data = abi.encodePacked("oddmaki.protocol");
        data = appendKeyValueAddress(data, "controller", oracle);
        data = appendKeyValueUint(data, "chain_id", chainId);
        data = appendKeyValueUint(data, "venue_id", venueId);
        data = appendKeyValueUint(data, "market_id", marketId);
        return keccak256(data);
    }

    /// @notice Appends ",key:0x..." to ancillary data.
    function appendKeyValueAddress(bytes memory ancillaryData, string memory key, address value)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(ancillaryData, ",", key, ":", _toUtf8BytesAddress(value));
    }

    /// @notice Appends ",key:123" to ancillary data.
    function appendKeyValueUint(bytes memory ancillaryData, string memory key, uint256 value)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(ancillaryData, ",", key, ":", _toUtf8BytesUint(value));
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    function _toUtf8BytesAddress(address value) private pure returns (bytes memory) {
        bytes memory addressBytes = abi.encodePacked(value);
        bytes memory asciiBytes = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(addressBytes[i]);
            asciiBytes[i * 2] = _toAsciiChar(b >> 4);
            asciiBytes[i * 2 + 1] = _toAsciiChar(b & 0x0f);
        }
        return asciiBytes;
    }

    function _toUtf8BytesUint(uint256 value) private pure returns (bytes memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return buffer;
    }

    function _toAsciiChar(uint8 nibble) private pure returns (bytes1) {
        return nibble < 10 ? bytes1(uint8(48 + nibble)) : bytes1(uint8(87 + nibble));
    }
}
