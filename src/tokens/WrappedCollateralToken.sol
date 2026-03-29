// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title WrappedCollateralToken
 * @notice ERC20 wrapper around collateral tokens for neg-risk (market group) position conversions
 * @dev When deployed from the Diamond (NegRisk domain), adapter = Diamond; only Diamond can mint/burn/release.
 *      Anyone can wrap/unwrap their own collateral 1:1.
 *      Design follows Polymarket's WrappedCollateral pattern.
 */
contract WrappedCollateralToken is ERC20 {
    error OnlyAdapter();
    error InvalidAmount();
    error TransferFailed();

    IERC20 public immutable COLLATERAL;
    /// @notice Adapter (Diamond proxy); only this address can mint/burn/release.
    address public immutable ADAPTER;

    event Wrapped(address indexed user, uint256 amount);
    event Unwrapped(address indexed user, uint256 amount);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    constructor(address _collateral, address _adapter, string memory name, string memory symbol) ERC20(name, symbol) {
        require(_collateral != address(0), "Invalid collateral");
        require(_adapter != address(0), "Invalid adapter");
        COLLATERAL = IERC20(_collateral);
        ADAPTER = _adapter;
    }

    modifier onlyAdapter() {
        _onlyAdapter();
        _;
    }

    function _onlyAdapter() internal {
        if (msg.sender != ADAPTER) revert OnlyAdapter();
    }

    function wrap(address to, uint256 amount) external {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        bool success = COLLATERAL.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        _mint(to, amount);
        emit Wrapped(to, amount);
    }

    function unwrap(address to, uint256 amount) external {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        _burn(msg.sender, amount);
        bool success = COLLATERAL.transfer(to, amount);
        if (!success) revert TransferFailed();
        emit Unwrapped(to, amount);
    }

    /**
     * @notice Mint wrapped tokens without depositing underlying collateral.
     * @dev Only called by the adapter (Diamond) during NegRisk position conversion.
     *      These tokens are immediately used in CTF.splitPosition(), which transfers them to CTF
     *      as collateral for the complementary YES+NO pairs. The solvency invariant is maintained
     *      because: (a) the minted WCT goes to CTF and backs real outcome tokens, and (b) for every
     *      NO token the user burns during conversion, 1 WCT is permanently locked in CTF at the
     *      burn address — this locked WCT offsets the USDC released via release(). In other words,
     *      the N burned NO positions lock N*amount WCT in CTF, and (N-1)*amount USDC is released
     *      to the user, leaving exactly enough USDC in this contract to cover all remaining legitimate
     *      redemption paths after resolution. Never call this outside the atomic convertPositions flow.
     */
    function mint(address to, uint256 amount) external onlyAdapter {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyAdapter {
        if (amount == 0 || from == address(0)) revert InvalidAmount();
        _burn(from, amount);
        emit Burned(from, amount);
    }

    /**
     * @notice Release underlying collateral to a recipient without burning wrapped tokens.
     * @dev Only called by the adapter (Diamond) during NegRisk position conversion to return
     *      (noCount-1)*amount USDC to the converter. The formula (noCount-1) is critical for
     *      solvency: the 1 withheld unit per position accounts for 1 WCT being permanently locked
     *      in CTF for each burned NO token (since the burn address can never redeem outcome tokens).
     *      The USDC drawn here is exactly covered by the WCT permanently locked in CTF from the
     *      burned NO positions — the invariant usdc_balance >= redeemable claims holds in all
     *      resolution scenarios when called correctly from convertPositions.
     */
    function release(address to, uint256 amount) external onlyAdapter {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        bool success = COLLATERAL.transfer(to, amount);
        if (!success) revert TransferFailed();
    }

    function decimals() public view virtual override returns (uint8) {
        try ERC20(address(COLLATERAL)).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
