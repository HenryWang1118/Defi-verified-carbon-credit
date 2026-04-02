// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title  VerifiedCarbonCredit (VCC)
 * @notice ERC-20 token representing verified carbon credits.
 *         1 VCC = 1 tonne of CO₂-equivalent offset verified under an
 *         internationally recognised standard (e.g. Verra VCS / Gold Standard).
 *
 * ── Token Design ──────────────────────────────────────────────────────────────
 *  Supply model : No fixed cap; minting is gated by authorised verifiers only,
 *                 mirroring the real-world verification process.
 *  Retirement   : Credits are permanently burned ("retired") when an offset
 *                 claim is made, preventing double-counting.
 *  Divisibility : 18 decimals allow fractional trading (e.g. 0.1 VCC = 100 kg CO₂e).
 *  Transferability: Freely tradeable; pause mechanism enables emergency halt.
 *
 * ── Roles ─────────────────────────────────────────────────────────────────────
 *  Owner    : Can add/remove verifiers, register projects, pause the contract.
 *  Verifier : Authorised third-party (e.g. Verra, Gold Standard) that mints
 *             credits after off-chain verification of a carbon project.
 *
 * UCL IFTE0007 — Asset Tokenisation Design Coursework
 */
contract VerifiedCarbonCredit is ERC20, ERC20Burnable, Ownable, Pausable {

    // ─── Data Structures ──────────────────────────────────────────────────────

    /// @dev Metadata for a registered carbon project
    struct CarbonProject {
        string  projectId;    // e.g. "VCS-1234"
        string  projectName;  // e.g. "Amazon REDD+ Conservation"
        string  country;      // host country
        string  methodology;  // e.g. "VM0015"
        uint32  vintage;      // year credits were generated
        bool    active;       // can mint against this project
    }

    /// @dev Immutable retirement receipt stored on-chain
    struct RetirementRecord {
        address retiredBy;    // wallet that retired the credits
        uint256 amount;       // amount retired (in wei, 1e18 = 1 tonne)
        uint256 timestamp;    // block timestamp of retirement
        string  beneficiary;  // entity claiming the offset (name / org)
        string  reason;       // e.g. "Scope 1 emissions offset FY2024"
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Tracks authorised verifiers (can mint)
    mapping(address => bool) public authorizedVerifiers;

    /// @notice Carbon projects registered on-chain, keyed by keccak256(projectId)
    mapping(bytes32 => CarbonProject) public projects;

    /// @notice Sequential retirement receipts (append-only, never deleted)
    RetirementRecord[] public retirements;

    /// @notice Cumulative amount retired across all time (in wei)
    uint256 public totalRetired;

    // ─── Events ────────────────────────────────────────────────────────────────

    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);

    event ProjectRegistered(
        bytes32 indexed projectHash,
        string  projectId,
        string  projectName,
        uint32  vintage
    );

    event CarbonCreditsMinted(
        address indexed to,
        uint256 amount,
        bytes32 indexed projectHash
    );

    /// @notice Emitted every time credits are permanently retired
    event CarbonCreditsRetired(
        uint256 indexed retirementId,
        address indexed retiredBy,
        uint256 amount,
        string  beneficiary,
        string  reason
    );

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyVerifier() {
        require(authorizedVerifiers[msg.sender], "VCC: caller is not a verifier");
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    constructor() ERC20("Verified Carbon Credit", "VCC") Ownable(msg.sender) {
        // Register one seed project so the contract is useful immediately
        _registerProject(
            "VCS-2476",
            "Amazon Basin REDD+ Conservation",
            "Brazil",
            "VM0015",
            2024
        );
        // Grant deployer verifier rights for demonstration purposes
        authorizedVerifiers[msg.sender] = true;
        emit VerifierAdded(msg.sender);
    }

    // ─── Owner Functions ───────────────────────────────────────────────────────

    /// @notice Grant verifier rights to an address
    function addVerifier(address verifier) external onlyOwner {
        authorizedVerifiers[verifier] = true;
        emit VerifierAdded(verifier);
    }

    /// @notice Revoke verifier rights
    function removeVerifier(address verifier) external onlyOwner {
        authorizedVerifiers[verifier] = false;
        emit VerifierRemoved(verifier);
    }

    /// @notice Register a new carbon project on-chain
    function registerProject(
        string calldata projectId,
        string calldata projectName,
        string calldata country,
        string calldata methodology,
        uint32  vintage
    ) external onlyOwner {
        _registerProject(projectId, projectName, country, methodology, vintage);
    }

    /// @notice Deactivate a project (no further minting allowed against it)
    function deactivateProject(bytes32 _projectHash) external onlyOwner {
        require(projects[_projectHash].active, "VCC: project already inactive");
        projects[_projectHash].active = false;
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Verifier Functions ────────────────────────────────────────────────────

    /**
     * @notice Mint carbon credits after off-chain verification of a carbon project.
     * @param to          Recipient (typically the project developer)
     * @param amount      Credits to mint — 1e18 = 1 tonne CO₂e
     * @param _projectHash keccak256(abi.encodePacked(projectId))
     */
    function mint(
        address to,
        uint256 amount,
        bytes32 _projectHash
    ) external onlyVerifier whenNotPaused {
        require(to != address(0),               "VCC: mint to zero address");
        require(amount > 0,                     "VCC: amount must be > 0");
        require(projects[_projectHash].active,  "VCC: project not active");
        _mint(to, amount);
        emit CarbonCreditsMinted(to, amount, _projectHash);
    }

    // ─── Public Functions ──────────────────────────────────────────────────────

    /**
     * @notice Permanently retire credits to claim the CO₂ offset.
     *         Retired credits are burned and cannot be transferred again.
     *         An immutable on-chain receipt is created for audit purposes.
     *
     * @param amount      Credits to retire — 1e18 = 1 tonne CO₂e
     * @param beneficiary Name / organisation claiming the offset
     * @param reason      Description of why the offset is being claimed
     */
    function retire(
        uint256 amount,
        string calldata beneficiary,
        string calldata reason
    ) external whenNotPaused {
        require(amount > 0,                           "VCC: amount must be > 0");
        require(balanceOf(msg.sender) >= amount,      "VCC: insufficient balance");
        require(bytes(beneficiary).length > 0,        "VCC: beneficiary required");

        _burn(msg.sender, amount);
        totalRetired += amount;

        uint256 retirementId = retirements.length;
        retirements.push(RetirementRecord({
            retiredBy:   msg.sender,
            amount:      amount,
            timestamp:   block.timestamp,
            beneficiary: beneficiary,
            reason:      reason
        }));

        emit CarbonCreditsRetired(retirementId, msg.sender, amount, beneficiary, reason);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @notice Retrieve a retirement receipt by sequential ID
    function getRetirement(uint256 retirementId)
        external view returns (RetirementRecord memory)
    {
        require(retirementId < retirements.length, "VCC: invalid retirement ID");
        return retirements[retirementId];
    }

    /// @notice Total number of retirement events ever recorded
    function totalRetirements() external view returns (uint256) {
        return retirements.length;
    }

    /// @notice Derive the project hash used as mapping key
    function projectHash(string calldata projectId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(projectId));
    }

    // ─── Internal Overrides ───────────────────────────────────────────────────

    /// @dev All token movements respect the pause flag
    function _update(address from, address to, uint256 value)
        internal override whenNotPaused
    {
        super._update(from, to, value);
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    function _registerProject(
        string memory projectId,
        string memory projectName,
        string memory country,
        string memory methodology,
        uint32  vintage
    ) private {
        bytes32 hash = keccak256(abi.encodePacked(projectId));
        require(!projects[hash].active, "VCC: project already registered");
        projects[hash] = CarbonProject({
            projectId:   projectId,
            projectName: projectName,
            country:     country,
            methodology: methodology,
            vintage:     vintage,
            active:      true
        });
        emit ProjectRegistered(hash, projectId, projectName, vintage);
    }
}
