const { BN, expectRevert, expectEvent, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;
const INVALID_SIGNATURE = "0x817548bed1e78b347866ab84382c8c9e944d0bc6ab1cdbbae754b68a0f9fd5ed3a54b6945aabc41b37d0b04078c56fd7cc1b5ee17a0fb04a4e5adc1ccf1ec1fe1c"
const POW_10_18 = new BN('10').pow(new BN('18'))
const NEGATIVE = new BN('-1')

const { expect } = require('chai');

const {
  jsonToTuple,
  OPCODE,
} = require('boomflow');

const fs = require('fs');
var testcases = JSON.parse(fs.readFileSync(`${__dirname}/boomflow.testcase.json`, 'utf8'));

async function shouldBehaveLikeCRCLPauseAndResume(crcl, from) {
  await pause(crcl, from);
  expect(await crcl.paused.call()).to.be.true;

  await resume(crcl, from);
  expect(await crcl.paused.call()).to.be.false;
}

async function shouldBehaveLikeCRCLDirectDeposit (token, crcl, operator, holder, recipient, amount) {
    const initialERC777TotalSupply = await token.totalSupply();
    const initialToERC777Balance = await token.balanceOf(crcl.address);
    const initialHolderERC777Balance = await token.balanceOf(recipient);
    
    const initialCRCLTotalSupply = await crcl.totalSupply();
    const initialRecipientCRCLBalance = await crcl.balanceOf(recipient);

    await CRCLDeposit(token, crcl, operator, holder, recipient, new BN(amount).mul(POW_10_18));

    const finalERC777TotalSupply = await token.totalSupply();
    const finalToERC777Balance = await token.balanceOf(crcl.address);
    const finalHolderERC777Balance = await token.balanceOf(holder);
    
    const finalCRCLTotalSupply = await crcl.totalSupply();
    const finalRecipientCRCLBalance = await crcl.balanceOf(recipient);

    expect(finalERC777TotalSupply.sub(initialERC777TotalSupply)).to.be.bignumber.equal(new BN(amount).mul(POW_10_18));
    expect(finalToERC777Balance.sub(initialToERC777Balance)).to.be.bignumber.equal(new BN(amount).mul(POW_10_18));
    expect(finalHolderERC777Balance.sub(initialHolderERC777Balance)).to.be.bignumber.equal(new BN('0'));

    expect(finalCRCLTotalSupply.sub(initialCRCLTotalSupply)).to.be.bignumber.equal(new BN(amount).mul(POW_10_18));
    expect(finalRecipientCRCLBalance.sub(initialRecipientCRCLBalance)).to.be.bignumber.equal(new BN(amount).mul(POW_10_18));
}

async function shouldBehaveLikeCRCLForceWithdraw (token, crcl, deferTime, admin, holder, recipient) {
  expect(await crcl.getDeferTime.call(holder, { from: admin })).to.be.bignumber.equal(new BN('0'));
  await expectRevert(
    crcl.forceWithdraw(recipient, { from: holder }),
    'FORCE_WITHDRAW_NOT_REQUESTED'
  );

  await crcl.setDeferTime(deferTime, { from: admin });
  expect(await crcl.deferTime.call()).to.be.bignumber.equal(new BN(deferTime));

  const initialERC777TotalSupply = await token.totalSupply();
  const initialToERC777Balance = await token.balanceOf(crcl.address);
  const initialRecipientERC777Balance = await token.balanceOf(recipient);
  
  const initialCRCLTotalSupply = await crcl.totalSupply();
  const initialHolderCRCLBalance = await crcl.balanceOf(holder);

  // Request force withdraw
  await crcl.requestForceWithdraw({ from: holder });
  const requestTime = await crcl.getDeferTime.call(holder);
  
  sleep(5)

  if (deferTime < 5) {
    await crcl.forceWithdraw(recipient, { from: holder });

    const finalERC777TotalSupply = await token.totalSupply();
    const finalToERC777Balance = await token.balanceOf(crcl.address);
    const finalRecipientERC777Balance = await token.balanceOf(recipient);
    
    const finalCRCLTotalSupply = await crcl.totalSupply();
    const finalHolderCRCLBalance = await crcl.balanceOf(holder);

    expect(finalERC777TotalSupply.sub(initialERC777TotalSupply)).to.be.bignumber.equal(new BN('0'));
    expect(finalToERC777Balance.sub(initialToERC777Balance)).to.be.bignumber.equal(initialHolderCRCLBalance.mul(NEGATIVE));
    expect(finalRecipientERC777Balance.sub(initialRecipientERC777Balance)).to.be.bignumber.equal(initialHolderCRCLBalance);

    expect(finalCRCLTotalSupply.sub(initialCRCLTotalSupply)).to.be.bignumber.equal(initialHolderCRCLBalance.mul(NEGATIVE));
    expect(finalHolderCRCLBalance.sub(initialHolderCRCLBalance)).to.be.bignumber.equal(initialHolderCRCLBalance.mul(NEGATIVE));
  } else {
    await expectRevert(
      crcl.forceWithdraw(recipient, { from: holder }),
      'TIME_LOCK_INCOMPLETE'
    );
  }
}

async function shouldBehaveLikeCRCLTransferFor(orderService, crcl, request, admin) {
  // Get balances of holder and recipients before the transactions.
  const initialHolderCRCLBalance = await crcl.balanceOf(request.userAddress);
  let initialRecipientCRCLBalances = []
  for (let i = 0; i < request.recipients.length; i++) {
    initialRecipientCRCLBalances.push(await crcl.balanceOf(request.recipients[i]));
  }

  const signedRequest = await createOrder(
      orderService,
      testcases.privateKeys[request.userAddress],
      request,
      crcl.address,
      null,
      OPCODE.Transfer
  )

  // Get request hash.
  const requestHash = await crcl.getTransferRequestHash.call(jsonToTuple(signedRequest[0]));

  // Get request record before the transactions.
  let recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.false;

  // Sanity check
  let tempRequest = JSON.parse(JSON.stringify(signedRequest[0]));
  tempRequest.userAddress = ZERO_ADDRESS
  await expectRevert(
    crcl.transferFor(tempRequest, signedRequest[1], { from: admin }),
    'CRCL: transfer for zero address'
  );

  tempRequest = JSON.parse(JSON.stringify(signedRequest[0]));
  tempRequest.amounts = tempRequest.amounts.slice(1)
  await expectRevert(
    crcl.transferFor(tempRequest, signedRequest[1], { from: admin }),
    'CRCL: amount length mismatch'
  );

  // Invalid Signature
  await expectRevert(
    crcl.transferFor(signedRequest[0], INVALID_SIGNATURE, { from: admin }),
    'CRCL: INVALID_TRANSFER_SIGNATURE'
  );

  // Execute the request.
  await crcl.transferFor(signedRequest[0], signedRequest[1], { from: admin });

  // Replay
  await expectRevert(
    crcl.transferFor(signedRequest[0], signedRequest[1], { from: admin }),
    'CRCL: the request has already been executed'
  );

  // Get order info of the maker and taker order after the transactions.
  recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.true;

  // Check balances of holder and recipients after the transactions.
  expect((await crcl.balanceOf(request.userAddress)).sub(initialHolderCRCLBalance)).to.be.bignumber.equal(new BN(sum(request.amounts)).mul(POW_10_18).mul(NEGATIVE));

  for (let i = 0; i < request.recipients.length; i++) {
    expect((await crcl.balanceOf(request.recipients[i])).sub(initialRecipientCRCLBalances[i])).to.be.bignumber.equal(new BN(request.amounts[i]).mul(POW_10_18));
  }

  let totalAccountCount = new BN(await crcl.accountTotal.call())
  let totalAccounts = []
  for (let i = 0; i < totalAccountCount; i += 100) {
    totalAccounts = totalAccounts.concat(await crcl.accountList.call(i));
  }

  expect(totalAccounts).to.include.members(request.recipients);
}

async function shouldBehaveLikeCRCLWithdraw(orderService, token, crcl, request, admin) {
  let holder = request.userAddress
  let recipient = request.recipient
  expect(await crcl.getTokenAddress.call()).to.be.equal(token.address)

  // Get balances of holder and recipients before the transactions.
  const initialERC777TotalSupply = await token.totalSupply();
  const initialToERC777Balance = await token.balanceOf(crcl.address);
  const initialRecipientERC777Balance = await token.balanceOf(recipient);
  
  const initialCRCLTotalSupply = await crcl.totalSupply();
  const initialHolderCRCLBalance = await crcl.balanceOf(holder);

  const signedRequest = await createOrder(
      orderService,
      testcases.privateKeys[request.userAddress],
      request,
      crcl.address,
      null,
      OPCODE.Withdraw
  )

  // Get request hash.
  const requestHash = await crcl.getRequestHash.call(jsonToTuple(signedRequest[0]));

  // Get request record before the transactions.
  let recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.false;

  // Invalid Signature
  await expectRevert(
    crcl.withdraw(signedRequest[0], INVALID_SIGNATURE, { from: admin }),
    'INVALID_WITHDRAW_SIGNATURE'
  );

  // Execute the request.
  await crcl.withdraw(signedRequest[0], signedRequest[1], { from: admin });

  // Replay
  await expectRevert(
    crcl.withdraw(signedRequest[0], signedRequest[1], { from: admin }),
    'CRCL: the request has already been executed'
  );

  // Get order info of the maker and taker order after the transactions.
  recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.true;

  // Check balances of holder and recipients after the transactions.
  const finalERC777TotalSupply = await token.totalSupply();
  const finalToERC777Balance = await token.balanceOf(crcl.address);
  const finalRecipientERC777Balance = await token.balanceOf(recipient);
  
  const finalCRCLTotalSupply = await crcl.totalSupply();
  const finalHolderCRCLBalance = await crcl.balanceOf(holder);

  expect(finalERC777TotalSupply.sub(initialERC777TotalSupply)).to.be.bignumber.equal(new BN('0'));
  expect(finalToERC777Balance.sub(initialToERC777Balance)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
  expect(finalRecipientERC777Balance.sub(initialRecipientERC777Balance)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18));

  expect(finalCRCLTotalSupply.sub(initialCRCLTotalSupply)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
  expect(finalHolderCRCLBalance.sub(initialHolderCRCLBalance)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
}

async function shouldBehaveLikeCRCLWithdrawCrossChain(orderService, token, crcl, request, admin) {
  let holder = request.userAddress
  let recipient = request.recipient
  expect(await crcl.getTokenAddress.call()).to.be.equal(token.address)

  // Get balances of holder and recipients before the transactions.
  const initialERC777TotalSupply = await token.totalSupply();
  const initialToERC777Balance = await token.balanceOf(crcl.address);
  const initialRecipientERC777Balance = await token.balanceOf(recipient);
  
  const initialCRCLTotalSupply = await crcl.totalSupply();
  const initialHolderCRCLBalance = await crcl.balanceOf(holder);

  const signedRequest = await createOrder(
      orderService,
      testcases.privateKeys[request.userAddress],
      request,
      crcl.address,
      null,
      OPCODE.Withdraw
  )

  // Get request hash.
  const requestHash = await crcl.getWithdrawCrossChainRequestHash.call(jsonToTuple(signedRequest[0]));

  // Get request record before the transactions.
  let recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.false;

  // Invalid Signature
  await expectRevert(
    crcl.withdrawCrossChain(signedRequest[0], INVALID_SIGNATURE, { from: admin }),
    'INVALID_WITHDRAW_SIGNATURE'
  );

  // Execute the request.
  await crcl.withdrawCrossChain(signedRequest[0], signedRequest[1], { from: admin });

  // Replay
  await expectRevert(
    crcl.withdrawCrossChain(signedRequest[0], signedRequest[1], { from: admin }),
    'CRCL: the request has already been executed'
  );

  // Get order info of the maker and taker order after the transactions.
  recorded = await crcl.recorded.call(requestHash);
  expect(recorded).to.be.true;

  // Check balances of holder and recipients after the transactions.
  const finalERC777TotalSupply = await token.totalSupply();
  const finalToERC777Balance = await token.balanceOf(crcl.address);
  const finalRecipientERC777Balance = await token.balanceOf(recipient);
  
  const finalCRCLTotalSupply = await crcl.totalSupply();
  const finalHolderCRCLBalance = await crcl.balanceOf(holder);

  expect(finalERC777TotalSupply.sub(initialERC777TotalSupply)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
  expect(finalToERC777Balance.sub(initialToERC777Balance)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
  expect(finalRecipientERC777Balance.sub(initialRecipientERC777Balance)).to.be.bignumber.equal(new BN('0'));

  expect(finalCRCLTotalSupply.sub(initialCRCLTotalSupply)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
  expect(finalHolderCRCLBalance.sub(initialHolderCRCLBalance)).to.be.bignumber.equal(new BN(request.amount).mul(POW_10_18).mul(NEGATIVE));
}

async function shouldBehaveLikeCRCLTransferFrom(crcl, holder, recipient, amount, admin) {
  expect(await crcl.isWhitelisted.call(admin)).to.be.false;
  await crcl.addWhitelisted(admin, { from: admin });
  expect(await crcl.isWhitelisted.call(admin)).to.be.true;

  // Get balances of holder and recipients before the transactions.
  const initialHolderCRCLBalance = await crcl.balanceOf(holder);
  let initialRecipientCRCLBalance = await crcl.balanceOf(recipient);

  // Sanity check
  await expectRevert(
    crcl.transferFrom(ZERO_ADDRESS, recipient, amount, { from: admin }),
    'CRCL: transfer from the zero address'
  );
  await expectRevert(
    crcl.transferFrom(holder, ZERO_ADDRESS, amount, { from: admin }),
    'CRCL: transfer to the zero address'
  );

  // Non-whitelisted member
  await expectRevert(
    crcl.transferFrom(holder, recipient, amount, { from: recipient }),
    'WhitelistedRole: caller does not have the Whitelisted role'
  );

  // Execute the request.
  await crcl.transferFrom(holder, recipient, amount, { from: admin })

  // Check balances of holder and recipients after the transactions.
  expect((await crcl.balanceOf(holder)).sub(initialHolderCRCLBalance)).to.be.bignumber.equal(new BN(amount).mul(NEGATIVE));
  expect((await crcl.balanceOf(recipient)).sub(initialRecipientCRCLBalance)).to.be.bignumber.equal(new BN(amount));

  let totalAccountCount = new BN(await crcl.accountTotal.call())
  let totalAccounts = []
  for (let i = 0; i < totalAccountCount; i += 100) {
    totalAccounts = totalAccounts.concat(await crcl.accountList.call(i));
  }

  expect(totalAccounts).to.include.members([recipient]);

  await crcl.removeWhitelisted(admin, { from: admin });
  expect(await crcl.isWhitelisted.call(admin)).to.be.false;
}

async function CRCLDeposit(token, crcl, operator, holder, recipient, amount) {
  await ERC777Mint(token, operator, holder, amount, "0");
  const { logs } =await ERC777Send(token, holder, crcl.address, amount, recipient);
  if (amount.toString() !== '0') {
    /*expectEvent.inLogs(logs, 'Transfer', {
      from: ZERO_ADDRESS,
      to: recipient,
      value: new BN(amount).mul(POW_10_18),
    });*/
    //console.log(logs)
  }
}

async function ERC777Mint(token, from, to, amount, tx_id) {
  return token.mint(to, amount, tx_id, { from });
}

async function ERC777Send(token, from, to, amount, data) {
  return token.send(to, amount, data, { from })
}

async function createOrder(orderService, seed, order, baseAssetAddress, quoteAssetAddress, op) {
  await orderService.signin(seed);

  let timestamp = orderService.getSystemTime();
  let typedData = await orderService.construct(order, baseAssetAddress, quoteAssetAddress, timestamp, op);
  let signature = await orderService.sign(typedData, op);

  return [typedData.message, signature]
}

function pause(crcl, from) {
  return crcl.Pause({ from });
}

function resume(crcl, from) {
  return crcl.Resume({ from });
}

function sum(obj) {
  return Object.keys(obj).reduce((sum,key) => sum + parseFloat(obj[key] || 0), 0);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = {
  shouldBehaveLikeCRCLTransferFrom,
  shouldBehaveLikeCRCLPauseAndResume,
  shouldBehaveLikeCRCLDirectDeposit,
  shouldBehaveLikeCRCLForceWithdraw,
  shouldBehaveLikeCRCLTransferFor,
  shouldBehaveLikeCRCLWithdraw,
  shouldBehaveLikeCRCLWithdrawCrossChain,
  ERC777Send,
  ERC777Mint,
  CRCLDeposit
};

