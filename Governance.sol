pragma solidity ^0.6.12;

/// SPDX-License-Identifier: MIT

import "./interface/ICrystalVault.sol";

import "./library/Address.sol";
import "./library/SafeMath.sol";


contract Governance {

  using SafeMath for uint;

  /// @notice Duration of voting on a proposal in seconds
  uint public votingPeriod = 172800; // 48 hours

  /// @notice Seconds since the end of the voting period before the proposal can be executed
  uint public executionDelay = 0;

  // @notice Seconds since execution was possible when a proposal is considered vetoed
  uint public executionExpiration = 604800; // 7 days

  /// @notice The required minimum number of votes in support of a proposal for it to succeed
  uint public quorumVotes = 5000e18;

  /// @notice The minimum number of votes required for an account to create a proposal
  uint public proposalThreshold = 100e18;

  /// @notice Location managing and freezing assests that support voting rights
  ICrystalVault public crystalVault;

  /// @notice The total number of proposals
  uint public proposalCount;

  /// @notice The record of all proposals ever proposed
  mapping (uint256 => Proposal) public proposals;

  /// @notice The group of addresses allowed to execute approved proposals
  mapping (address => bool) public governers;

  struct Proposal {
    uint id;
    address proposer;
    address executor;
    uint startTime;
    uint forVotes;
    uint againstVotes;
    bytes32 txHash;
    mapping (address => Receipt) receipts;
  }

  /// @notice Ballot receipt record for a voter
  struct Receipt {
    bool hasVoted;
    bool support;
    uint votes;
  }

  /// @notice Possible states that a proposal may be in
  enum ProposalState {
    Active,
    Defeated,
    PendingExecution,
    ReadyForExecution,
    Executed,
    Vetoed
  }

  event NewVote(address voter, uint proposalId, bool support, uint votes);
  event NewProposal(address proposer, uint proposalId);
  event ProposalExecuted(address executor, uint proposalId);
  event GovernerAdded(address governer);
  event GovernerRemoved(address governer);

  /// @notice If the votingPeriod is changed and the user votes again, the freeze period will be reset.
  modifier freezeVotes() {
    crystalVault.freeze(msg.sender, votingPeriod);
    _;
  }

  modifier isGoverner() {
    require(governers[msg.sender] == true, "Governance::isGoverner: INSUFFICIENT_PERMISSION");
    _;
  }

  constructor(address _crystalVault, address _governer) public {
    crystalVault = ICrystalVault(_crystalVault);
    governers[_governer] = true;
  }

  function state(uint proposalId)
    public
    view
    returns (ProposalState)
  {
    require(proposalCount >= proposalId && proposalId > 0, "Governance::state: invalid proposal id");
    Proposal storage proposal = proposals[proposalId];

    if (block.timestamp <= proposal.startTime.add(votingPeriod)) {
      return ProposalState.Active;
    } else if (proposal.executor != address(0)) {
      return ProposalState.Executed;
    } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes) {
      return ProposalState.Defeated;
    } else if (block.timestamp < proposal.startTime.add(votingPeriod).add(executionDelay)) {
      return ProposalState.PendingExecution;
    } else if (block.timestamp < proposal.startTime.add(votingPeriod).add(executionDelay).add(executionExpiration)) {
      return ProposalState.ReadyForExecution;
    } else {
      return ProposalState.Vetoed;
    }
  }

  function getVote(uint _proposalId, address _voter)
    public
    view
    returns (bool)
  {
    return proposals[_proposalId].receipts[_voter].support;
  }

  function execute(uint _proposalId, address _target, uint _value, bytes memory _data)
    public
    payable
    isGoverner
    returns (bytes memory)
  {
    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));
    Proposal storage proposal = proposals[_proposalId];

    require(proposal.txHash == txHash, "Governance::execute: Invalid proposal");
    require(state(_proposalId) == ProposalState.ReadyForExecution, "Governance::execute: Cannot be executed");

    (bool success, bytes memory returnData) = _target.call.value(_value)(_data);
    require(success, "Governance::execute: Transaction execution reverted.");
    proposal.executor = msg.sender;

    emit ProposalExecuted(proposal.executor, proposal.id);

    return returnData;
  }

  function propose(address _target, uint _value, bytes memory _data)
    public
    freezeVotes
  {
    uint votes = crystalVault.quadraticVotes(msg.sender);

    require(votes > proposalThreshold, "Governance::propose: proposer votes below proposal threshold");

    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));

    proposalCount++;
    Proposal memory newProposal = Proposal({
      id: proposalCount,
      proposer: msg.sender,
      executor: address(0),
      startTime: block.timestamp,
      forVotes: 0,
      againstVotes: 0,
      txHash: txHash
    });

    proposals[newProposal.id] = newProposal;

    emit NewProposal(newProposal.proposer, newProposal.id);
  }

  function vote(uint _proposalId, bool _support) public freezeVotes {
    require(state(_proposalId) == ProposalState.Active, "Governance::vote: voting is closed");
    Proposal storage proposal = proposals[_proposalId];
    Receipt storage receipt = proposal.receipts[msg.sender];
    require(receipt.hasVoted == false, "Governance::vote: voter already voted");

    uint256 votes = crystalVault.quadraticVotes(msg.sender);

    if (_support) {
      proposal.forVotes = proposal.forVotes.add(votes);
    } else {
      proposal.againstVotes = proposal.againstVotes.add(votes);
    }

    receipt.hasVoted = true;
    receipt.support = _support;
    receipt.votes = votes;

    emit NewVote(msg.sender, _proposalId, _support, votes);
  }

  function addGoverner(address _governer) public isGoverner {
    governers[_governer] = true;
    emit GovernerAdded(_governer);
  }

  function removeGoverner(address _governer) public isGoverner {
    governers[_governer] = false;
    emit GovernerRemoved(_governer);
  }

  function setVotingPeriod(uint _seconds) public isGoverner {
    require(_seconds > 0, "Governance::setVotingPeriod: CANNOT_BE_ZERO");
    votingPeriod = _seconds;
  }

  function setExecutionDelay(uint _seconds) public isGoverner {
    executionDelay = _seconds;
  }

  function setExecutionExpiration(uint _seconds) public isGoverner {
    require(_seconds > 0, "Governance::setExecutionExpiration: CANNOT_BE_ZERO");
    executionExpiration = _seconds;
  }

  function setQuorumVotes(uint _votes) public isGoverner {
    require(_votes > 0, "Governance::setQuorumVotes: CANNOT_BE_ZERO");
    quorumVotes = _votes;
  }

  function setProposalThreshold(uint _votes) public isGoverner {
    proposalThreshold = _votes;
  }

}
