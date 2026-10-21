pragma solidity >=0.8.20;

import "@gnosis-guild/zodiac-core/contracts/core/Module.sol";
import "./interfaces/RealitioV3.sol";

abstract contract RealityModule is Module {
    bytes32 public constant INVALIDATED =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    bytes32 public constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    // keccak256(
    //     "EIP712Domain(uint256 chainId,address verifyingContract)"
    // );

    bytes32 public constant TRANSACTION_TYPEHASH =
        0x72e9670a7ee00f5fbf1049b8c38e3f22fab7e9b85029e85cf9412f17fdd5c2ad;
    // keccak256(
    //     "Transaction(address to,uint256 value,bytes data,uint8 operation,uint256 nonce)"
    // );

    event ProposalQuestionCreated(
        bytes32 indexed questionId,
        string indexed proposalId
    );
    event ProposalExecuted(string proposalId, bytes32 txHash, uint256 txIndex);
    event RealityModuleSetup(
        address indexed initiator,
        address indexed owner,
        address indexed avatar,
        address target
    );
    event OracleSet(RealitioV3 oracle);
    event SetQuestionTimeout(uint32 questionTimeout);
    event SetQuestionCooldown(uint32 questionCooldown);
    event SetAnswerExpiration(uint32 answerExpiration);
    event SetArbitrator(address indexed questionArbitrator);
    event SetMinimumBond(uint256 minimumBond);
    event SetTemplate(uint256 templateId);

    RealitioV3 public oracle;
    uint256 public template;
    uint32 public questionTimeout;
    uint32 public questionCooldown;
    uint32 public answerExpiration;
    address public questionArbitrator;
    uint256 public minimumBond;

    // Mapping of question hash to question id. Special case: INVALIDATED for question hashes that have been invalidated
    mapping(bytes32 => bytes32) public questionIds;
    // Mapping of questionHash to transactionHash to execution state
    mapping(bytes32 => mapping(bytes32 => bool))
        public executedProposalTransactions;

    /// @param _owner Address of the owner
    /// @param _avatar Address of the avatar (e.g. a Safe)
    /// @param _target Address of the contract that will call exec function
    /// @param _oracle Address of the oracle (e.g. Realitio)
    /// @param timeout Timeout in seconds that should be required for the oracle
    /// @param cooldown Cooldown in seconds that should be required after a oracle provided answer
    /// @param expiration Duration that a positive answer of the oracle is valid in seconds (or 0 if valid forever)
    /// @param bond Minimum bond that is required for an answer to be accepted
    /// @param templateId ID of the template that should be used for proposal questions (see https://github.com/realitio/realitio-dapp#structuring-and-fetching-information)
    /// @param arbitrator Address of the arbitrator that will secure the oracle resolution
    /// @notice There need to be at least 60 seconds between end of cooldown and expiration
    constructor(
        address _owner,
        address _avatar,
        address _target,
        RealitioV3 _oracle,
        uint32 timeout,
        uint32 cooldown,
        uint32 expiration,
        uint256 bond,
        uint256 templateId,
        address arbitrator
    ) {
        bytes memory initParams = abi.encode(
            _owner,
            _avatar,
            _target,
            _oracle,
            timeout,
            cooldown,
            expiration,
            bond,
            templateId,
            arbitrator
        );
        setUp(initParams);
    }

    function setUp(bytes memory initParams) public override initializer {
        (
            address _owner,
            address _avatar,
            address _target,
            RealitioV3 _oracle,
            uint32 timeout,
            uint32 cooldown,
            uint32 expiration,
            uint256 bond,
            uint256 templateId,
            address arbitrator
        ) = abi.decode(
                initParams,
                (
                    address,
                    address,
                    address,
                    RealitioV3,
                    uint32,
                    uint32,
                    uint32,
                    uint256,
                    uint256,
                    address
                )
            );
        __Ownable_init(msg.sender);
        require(_avatar != address(0), "Avatar can not be zero address");
        require(_target != address(0), "Target can not be zero address");
        setAvatar(_avatar);
        setTarget(_target);
        setOracle(_oracle);
        setAnswerExpiration(expiration);
        setQuestionTimeout(timeout);
        setQuestionCooldown(cooldown);
        setArbitrator(arbitrator);
        setMinimumBond(bond);
        setTemplate(templateId);

        transferOwnership(_owner);

        emit RealityModuleSetup(msg.sender, _owner, avatar, target);
    }

    /// @dev Sets the `oracle` address
    /// @param _oracle Address to be used as the oracle for this module
    /// @notice This can only be called by the `owner`
    function setOracle(RealitioV3 _oracle) public onlyOwner {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    /// @dev Sets the question timeout
    /// @param timeout Timeout, in seconds, between when an answer is set and when it is final
    /// @notice This can only be called by the `owner`
    /// @notice Timeout must be greater than `0`
    function setQuestionTimeout(uint32 timeout) public onlyOwner {
        require(timeout > 0, "Timeout has to be greater 0");
        require(timeout < 365 days, "timeout must be less than 365 days");
        questionTimeout = timeout;
        emit SetQuestionTimeout(timeout);
    }

    /// @dev Sets the cooldown before an answer is usable
    /// @param cooldown Cooldown, in seconds, that should be required after a oracle provided answer
    /// @notice This can only be called by the `owner`
    /// @notice There need to be at least 60 seconds between end of cooldown and expiration
    function setQuestionCooldown(uint32 cooldown) public onlyOwner {
        uint32 expiration = answerExpiration;
        require(
            expiration == 0 || expiration - cooldown >= 60,
            "There need to be at least 60s between end of cooldown and expiration"
        );
        questionCooldown = cooldown;
        emit SetQuestionCooldown(cooldown);
    }

    /// @dev Sets the duration for which a positive answer is valid
    /// @param expiration Duration that a positive answer of the oracle is valid, in seconds (or 0 if valid forever)
    /// @notice A proposal with an expired answer is the same as a proposal that has been marked invalid
    /// @notice There need to be at least 60 seconds between end of cooldown and expiration
    /// @notice This can only be called by the `owner`
    function setAnswerExpiration(uint32 expiration) public onlyOwner {
        require(
            expiration == 0 || expiration - questionCooldown >= 60,
            "There need to be at least 60s between end of cooldown and expiration"
        );
        answerExpiration = expiration;
        emit SetAnswerExpiration(expiration);
    }

    /// @dev Sets the question arbitrator that will be used for future questions
    /// @param arbitrator Address of the arbitrator
    /// @notice This can only be called by the `owner`
    function setArbitrator(address arbitrator) public onlyOwner {
        questionArbitrator = arbitrator;
        emit SetArbitrator(arbitrator);
    }

    /// @dev Sets the minimum bond that is required for an answer to be accepted
    /// @param bond Minimum bond that is required for an answer to be accepted
    /// @notice This can only be called by the `owner`
    function setMinimumBond(uint256 bond) public onlyOwner {
        minimumBond = bond;
        emit SetMinimumBond(bond);
    }

    /// @dev Sets the template that should be used for future questions
    /// @param templateId ID of the template that should be used for proposal questions
    /// @notice Check https://github.com/realitio/realitio-dapp#structuring-and-fetching-information for more information
    /// @notice This can only be called by the `owner`
    function setTemplate(uint256 templateId) public onlyOwner {
        template = templateId;
        emit SetTemplate(templateId);
    }

    /// @dev Function to add a proposal that should be considered for execution
    /// @param proposalId Id that should identify the proposal uniquely
    /// @param txHashes EIP-712 hashes of the transactions that should be executed
    /// @notice The nonce used for the question by this function is always `0`
    function addProposal(
        string memory proposalId,
        bytes32[] memory txHashes
    ) public {
        addProposalWithNonce(proposalId, txHashes, 0);
    }

    /// @dev Function to add a proposal that should be considered for execution
    /// @param proposalId Id that should identify the proposal uniquely
    /// @param txHashes EIP-712 hashes of the transactions that should be executed
    /// @param nonce Nonce that should be used when asking the question on the oracle
    function addProposalWithNonce(
        string memory proposalId,
        bytes32[] memory txHashes,
        uint256 nonce
    ) public {
        // We generate the question string used for the oracle
        string memory question = buildQuestion(proposalId, txHashes);
        bytes32 questionHash = keccak256(bytes(question));
        if (nonce > 0) {
            // Previous nonce must have been invalidated by the oracle.
            // However, if the proposal was internally invalidated, it should not be possible to ask it again.
            bytes32 currentQuestionId = questionIds[questionHash];
            require(
                currentQuestionId != INVALIDATED,
                "This proposal has been marked as invalid"
            );
            require(
                oracle.resultFor(currentQuestionId) == INVALIDATED,
                "Previous proposal was not invalidated"
            );
        } else {
            require(
                questionIds[questionHash] == bytes32(0),
                "Proposal has already been submitted"
            );
        }
        bytes32 expectedQuestionId = getQuestionId(question, nonce);
        // Set the question hash for this question id
        questionIds[questionHash] = expectedQuestionId;
        bytes32 questionId = askQuestion(question, nonce);
        require(expectedQuestionId == questionId, "Unexpected question id");
        emit ProposalQuestionCreated(questionId, proposalId);
    }

    function askQuestion(
        string memory question,
        uint256 nonce
    ) internal virtual returns (bytes32);

    /// @dev Marks a proposal as invalid, preventing execution of the connected transactions
    /// @param proposalId Id that should identify the proposal uniquely
    /// @param txHashes EIP-712 hashes of the transactions that should be executed
    /// @notice This can only be called by the owner
    function markProposalAsInvalid(
        string memory proposalId,
        bytes32[] memory txHashes // owner only is checked in markProposalAsInvalidByHash(bytes32)
    ) public {
        string memory question = buildQuestion(proposalId, txHashes);
        bytes32 questionHash = keccak256(bytes(question));
        markProposalAsInvalidByHash(questionHash);
    }

    /// @dev Marks a question hash as invalid, preventing execution of the connected transactions
    /// @param questionHash Question hash calculated based on the proposal id and txHashes
    /// @notice This can only be called by the owner
    function markProposalAsInvalidByHash(
        bytes32 questionHash
    ) public onlyOwner {
        questionIds[questionHash] = INVALIDATED;
    }

    /// @dev Marks a proposal with an expired answer as invalid, preventing execution of the connected transactions
    /// @param questionHash Question hash calculated based on the proposal id and txHashes
    function markProposalWithExpiredAnswerAsInvalid(
        bytes32 questionHash
    ) public {
        uint32 expirationDuration = answerExpiration;
        require(expirationDuration > 0, "Answers are valid forever");
        bytes32 questionId = questionIds[questionHash];
        require(questionId != INVALIDATED, "Proposal is already invalidated");
        require(
            questionId != bytes32(0),
            "No question id set for provided proposal"
        );
        require(
            oracle.resultFor(questionId) == bytes32(uint256(1)),
            "Only positive answers can expire"
        );
        uint32 finalizeTs = oracle.getFinalizeTS(questionId);
        require(
            finalizeTs + uint256(expirationDuration) < block.timestamp,
            "Answer has not expired yet"
        );
        questionIds[questionHash] = INVALIDATED;
    }

    /// @dev Executes the transactions of a proposal via the target if accepted
    /// @param proposalId Id that should identify the proposal uniquely
    /// @param txHashes EIP-712 hashes of the transactions that should be executed
    /// @param to Target of the transaction that should be executed
    /// @param value Wei value of the transaction that should be executed
    /// @param data Data of the transaction that should be executed
    /// @param operation Operation (Call or Delegatecall) of the transaction that should be executed
    /// @notice The txIndex used by this function is always `0`
    function executeProposal(
        string memory proposalId,
        bytes32[] memory txHashes,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) public {
        executeProposalWithIndex(
            proposalId,
            txHashes,
            to,
            value,
            data,
            operation,
            0
        );
    }

    /// @dev Executes the transactions of a proposal via the target if accepted
    /// @param proposalId Id that should identify the proposal uniquely
    /// @param txHashes EIP-712 hashes of the transactions that should be executed
    /// @param to Target of the transaction that should be executed
    /// @param value Wei value of the transaction that should be executed
    /// @param data Data of the transaction that should be executed
    /// @param operation Operation (Call or Delegatecall) of the transaction that should be executed
    /// @param txIndex Index of the transaction hash in txHashes. This is used as the nonce for the transaction, to make the tx hash unique
    function executeProposalWithIndex(
        string memory proposalId,
        bytes32[] memory txHashes,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 txIndex
    ) public {
        // We use the hash of the question to check the execution state, as the other parameters might change, but the question not
        bytes32 questionHash = keccak256(
            bytes(buildQuestion(proposalId, txHashes))
        );
        // Lookup question id for this proposal
        bytes32 questionId = questionIds[questionHash];
        // Question hash needs to set to be eligible for execution
        require(
            questionId != bytes32(0),
            "No question id set for provided proposal"
        );
        require(questionId != INVALIDATED, "Proposal has been invalidated");

        bytes32 txHash = getTransactionHash(
            to,
            value,
            data,
            operation,
            txIndex
        );
        require(txHashes[txIndex] == txHash, "Unexpected transaction hash");

        // Check that the result of the question is 1 (true)
        require(
            oracle.resultFor(questionId) == bytes32(uint256(1)),
            "Transaction was not approved"
        );
        uint256 minBond = minimumBond;
        require(
            minBond == 0 || minBond <= oracle.getBond(questionId),
            "Bond on question not high enough"
        );
        uint32 finalizeTs = oracle.getFinalizeTS(questionId);
        // The answer is valid in the time after the cooldown and before the expiration time (if set).
        require(
            finalizeTs + uint256(questionCooldown) < block.timestamp,
            "Wait for additional cooldown"
        );
        uint32 expiration = answerExpiration;
        require(
            expiration == 0 ||
                finalizeTs + uint256(expiration) >= block.timestamp,
            "Answer has expired"
        );
        // Check this is either the first transaction in the list or that the previous question was already approved
        require(
            txIndex == 0 ||
                executedProposalTransactions[questionHash][
                    txHashes[txIndex - 1]
                ],
            "Previous transaction not executed yet"
        );
        // Check that this question was not executed yet
        require(
            !executedProposalTransactions[questionHash][txHash],
            "Cannot execute transaction again"
        );
        // Mark transaction as executed
        executedProposalTransactions[questionHash][txHash] = true;
        // Execute the transaction via the target.
        require(exec(to, value, data, operation), "Module transaction failed");
        emit ProposalExecuted(proposalId, txHash, txIndex);
    }

    /// @dev Build the question by combining the proposalId and the hex string of the hash of the txHashes
    /// @param proposalId Id of the proposal that proposes to execute the transactions represented by the txHashes
    /// @param txHashes EIP-712 Hashes of the transactions that should be executed
    function buildQuestion(
        string memory proposalId,
        bytes32[] memory txHashes
    ) public pure returns (string memory) {
        requireReasonableProposalId(proposalId);
        string memory txsHash = bytes32ToAsciiString(
            keccak256(abi.encodePacked(txHashes))
        );
        return string(abi.encodePacked(proposalId, bytes3(0xe2909f), txsHash));
    }

    /// @dev Reverts unless `proposalId` is 1-128 bytes long and consists solely
    ///      of ASCII alphanumerics, hyphen (`-`) and underscore (`_`).
    /// @notice 
    ///      proposalId is interpolated into the oracle question and shown to human answerers via a JSON template
    ///      Attacks can be detected at the social layer and usually just cause the attacker to lose their bond
    ///      However it's easier for humans if the proposal ID is always just an ID.
    ///      In practice Snapshot proposal IDs are either CIDs or 32-byte hashes.
    ///      But we leave room for reasonable alternatives.
    function requireReasonableProposalId(string memory proposalId) internal pure {
        bytes memory b = bytes(proposalId);
        require(b.length > 0, "proposalId must not be empty");
        require(b.length <= 128, "proposalId too long");
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            bool ok = (c >= 0x30 && c <= 0x39) || // 0-9
                (c >= 0x41 && c <= 0x5a) || // A-Z
                (c >= 0x61 && c <= 0x7a) || // a-z
                c == 0x2d || // -
                c == 0x5f; // _
            require(ok, "proposalId has invalid characters");
        }
    }

    /// @dev Generate the question id.
    /// @notice It is required that this is the same as for the oracle implementation used.
    function getQuestionId(
        string memory question,
        uint256 nonce
    ) public view returns (bytes32) {
        // Ask the question with a starting time of 0, so that it can be immediately answered
        bytes32 contentHash = keccak256(
            abi.encodePacked(template, uint32(0), question)
        );
        return
            keccak256(
                abi.encodePacked(
                    contentHash,
                    questionArbitrator,
                    questionTimeout,
                    minimumBond,
                    oracle,
                    this,
                    nonce
                )
            );
    }

    /// @dev Returns the chain id used by this contract.
    function getChainId() public view returns (uint256) {
        uint256 id;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            id := chainid()
        }
        return id;
    }

    /// @dev Generates the data for the module transaction hash (required for signing)
    function generateTransactionHashData(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 nonce
    ) public view returns (bytes memory) {
        uint256 chainId = getChainId();
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, this)
        );
        bytes32 transactionHash = keccak256(
            abi.encode(
                TRANSACTION_TYPEHASH,
                to,
                value,
                keccak256(data),
                operation,
                nonce
            )
        );
        return
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                domainSeparator,
                transactionHash
            );
    }

    function getTransactionHash(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 nonce
    ) public view returns (bytes32) {
        return
            keccak256(
                generateTransactionHashData(to, value, data, operation, nonce)
            );
    }

    function bytes32ToAsciiString(
        bytes32 _bytes
    ) internal pure returns (string memory) {
        bytes memory s = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(bytes1(_bytes << (i * 8)));
            uint8 hi = uint8(b) / 16;
            uint8 lo = uint8(b) % 16;
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    function char(uint8 b) internal pure returns (bytes1 c) {
        if (b < 10) return bytes1(b + 0x30);
        else return bytes1(b + 0x57);
    }
}
