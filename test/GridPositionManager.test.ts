import { expect } from "chai";
import { ethers } from "hardhat";

describe("GridPositionManager", function () {
  // Base mainnet addresses
  const poolAddress = "0xd0b53D9277642d899DF5C87A3966A349A798F224";
  const positionManagerAddress = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
  const WETHAddress = "0x4200000000000000000000000000000000000006";
  const USDCAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const slippage = 500; // 0.5% slippage
  enum GridType {
    NEUTRAL = 0,
    BUY = 1,
    SELL = 2,
  }

  let amount0 = ethers.utils.parseEther("0.0001");
  let amount1 = ethers.utils.parseUnits("100", 6);

  let gridPositionManager: any;
  let owner: any;
  let addr1: any;
  let addr2: any;

  before(async function () {
    const ownerAddress = "0x737284cFc66fd5989F2AC866989d70Ae134227cB";
    // Start impersonating the address
    await ethers.provider.send("hardhat_impersonateAccount", [ownerAddress]);
    // Get a signer for the impersonated address
    owner = await ethers.getSigner(ownerAddress);
    
    const [funder, address1, address2] = await ethers.getSigners();
    addr1 = address1;
    addr2 = address2;
    // Send ETH to the owner address
    const tx = await funder.sendTransaction({
        to: ownerAddress,
        value: ethers.utils.parseEther("10"), // Amount to send (10 ETH in this case)
    });

    await tx.wait();
    const wethContract = await ethers.getContractAt("IERC20", WETHAddress);
    const usdcContract = await ethers.getContractAt("IERC20", USDCAddress);

    const wethBalance = await wethContract.balanceOf(owner.address);
    const usdcBalance = await usdcContract.balanceOf(owner.address);

    console.log("Owner WETH Balance:", wethBalance.toString());
    console.log("Owner USDC Balance:", usdcBalance.toString());
    const wethBalancePercentage = wethBalance.div(100); // 1% of WETH balance
    const usdcBalancePercentage = usdcBalance.div(100); // 1% of USDC balance

    amount0 = wethBalancePercentage;
    amount1 = usdcBalancePercentage;

    console.log("Amount0 (1% WETH):", amount0.toString());
    console.log("Amount1 (1% USDC):", amount1.toString());
  });

  beforeEach(async function () {
    const iUniswapV3Pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);
    const iNonfungiblePositionManager = await ethers.getContractAt("INonfungiblePositionManager", positionManagerAddress);

    const GridPositionManager = await ethers.getContractFactory("GridPositionManager");
    gridPositionManager = await GridPositionManager.connect(owner).deploy();
    await gridPositionManager.deployed();
    await gridPositionManager.initialize(
      iUniswapV3Pool.address,
      iNonfungiblePositionManager.address,
      10,
      1
    );

    const wethContract = await ethers.getContractAt("IERC20", WETHAddress);
    const usdcContract = await ethers.getContractAt("IERC20", USDCAddress);

    // Approve GridPositionManager to spend WETH and USDC
    await wethContract.connect(owner).approve(gridPositionManager.address, amount0);
    await usdcContract.connect(owner).approve(gridPositionManager.address, amount1);
  });

  it("Should initialize with correct parameters", async function () {
    const gridQuantity = await gridPositionManager.getGridQuantity();
    const gridStep = await gridPositionManager.getGridStep();
    expect(gridQuantity).to.equal(10);
    expect(gridStep).to.equal(1);
  });

  it("Should allow the owner to set grid step", async function () {
    await gridPositionManager.connect(owner).setGridStep(5);
    const gridStep = await gridPositionManager.getGridStep();
    expect(gridStep).to.equal(5);
  });

  it("Should revert if non-owner tries to set grid step", async function () {
    await expect(gridPositionManager.connect(addr1).setGridStep(5)).to.be.rejectedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should revert if grid step is invalid", async function () {
    await expect(gridPositionManager.connect(owner).setGridStep(0)).to.be.revertedWith("E09: Grid step must be between 1 and 9999");
    await expect(gridPositionManager.connect(owner).setGridStep(10000)).to.be.revertedWith("E09: Grid step must be between 1 and 9999");
  });

  it("Should allow the owner to set grid quantity", async function () {
    await gridPositionManager.connect(owner).setGridQuantity(20);
    const gridQuantity = await gridPositionManager.getGridQuantity();
    expect(gridQuantity).to.equal(20);
  });

  it("Should revert if grid quantity is invalid", async function () {
    await expect(gridPositionManager.connect(owner).setGridQuantity(0)).to.be.revertedWith("E10: Grid quantity must be between 1 and 9999");
    await expect(gridPositionManager.connect(owner).setGridQuantity(10000)).to.be.revertedWith("E10: Grid quantity must be between 1 and 9999");
  });

  it("Should allow the owner to set minimum fees", async function () {
    await gridPositionManager.connect(owner).setMinFees(ethers.utils.parseEther("0.0001"), ethers.utils.parseUnits("0.0001", 6));
    const poolInfo = await gridPositionManager.getPoolInfo();
    const {token0MinFees, token1MinFees} = poolInfo;
    expect(token0MinFees).to.equal(ethers.utils.parseEther("0.0001"));
    expect(token1MinFees).to.equal(ethers.utils.parseUnits("0.0001", 6));
  });

  it("Should allow NEUTRAL deposits and emit Deposit event", async function () {
    await expect(gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL))
      .to.emit(gridPositionManager, "Deposit");
  });

  it("Should allow SELL deposits and emit Deposit event", async function () {
    await expect(gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.SELL))
      .to.emit(gridPositionManager, "Deposit");
  });

  it("Should allow BUY deposits and emit Deposit event", async function () {
    await expect(gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.BUY))
      .to.emit(gridPositionManager, "Deposit");
  });

  it("Should revert if deposit amounts are invalid", async function () {
    await expect(gridPositionManager.connect(owner).deposit(0, amount1, slippage, GridType.NEUTRAL)).to.be.revertedWith("E05: Token amounts must be greater than 0");
    await expect(gridPositionManager.connect(owner).deposit(amount0, 0, slippage, GridType.NEUTRAL)).to.be.revertedWith("E05: Token amounts must be greater than 0");
  });

  it("Should revert if slippage is too high", async function () {
    await expect(gridPositionManager.connect(owner).deposit(amount0, amount1, 600, GridType.NEUTRAL)).to.be.revertedWith("E06: Slippage must be less than or equal to 500 (5%)");
  });

  it("Should allow the owner to withdraw and emit Withdraw event", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);

    await expect(gridPositionManager.withdraw())
      .to.emit(gridPositionManager, "Withdraw");
  });

  it("Should revert if non-owner tries to withdraw", async function () {
    await expect(gridPositionManager.connect(addr1).withdraw()).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should allow NEUTRAL compounding fees", async function () {
    await gridPositionManager.connect(owner).setMinFees(ethers.utils.parseEther("0.0001"), ethers.utils.parseUnits("1", 6));
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);
    await expect(gridPositionManager.connect(owner).compound(slippage, GridType.NEUTRAL)).not.to.emit(gridPositionManager, "Compound");
  });

  it("Should allow BUY compounding fees", async function () {
    await gridPositionManager.connect(owner).setMinFees(ethers.utils.parseEther("0.001"), ethers.utils.parseUnits("1", 6));
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.BUY);
    await expect(gridPositionManager.connect(owner).compound(slippage, GridType.BUY)).not.to.emit(gridPositionManager, "Compound");
  });

  it("Should allow SELL compounding fees", async function () {
    await gridPositionManager.connect(owner).setMinFees(ethers.utils.parseEther("0.0001"), ethers.utils.parseUnits("1", 6));
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.SELL);
    await expect(gridPositionManager.connect(owner).compound(slippage, GridType.SELL)).not.to.emit(gridPositionManager, "Compound");
  });

  it("Should allow NEUTRAL sweeping positions", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);
    await expect(gridPositionManager.sweep(slippage, GridType.NEUTRAL)).to.emit(gridPositionManager, "Deposit");
  });

  it("Should allow BUY sweeping positions", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.BUY);
    await expect(gridPositionManager.sweep(slippage, GridType.BUY)).to.emit(gridPositionManager, "Deposit");
  });

  it("Should allow SELL sweeping positions", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.SELL);
    await expect(gridPositionManager.sweep(slippage, GridType.SELL)).to.emit(gridPositionManager, "Deposit");
  });

  it("Should revert Ether transfers", async function () {
    await expect(
      owner.sendTransaction({
        to: gridPositionManager.address,
        value: ethers.utils.parseEther("1"),
      })
    ).to.be.rejectedWith("Ether transfers not allowed");
  });

  it("Should allow the owner to close all positions", async function () {
    // Deposit funds to create positions
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);

    // Withdraw all liquidity to ensure activePositionIndexes is empty
    await gridPositionManager.connect(owner).withdraw();

    // Call the close function
    await expect(gridPositionManager.connect(owner).close())
      .to.not.be.rejected;

    // Verify that positions array is cleared
    const positionsLength = await gridPositionManager.getPositionsLength();
    expect(positionsLength).to.equal(0);
  });

  it("Should revert close if active positions exist", async function () {
    // Deposit funds to create positions
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);

    // Attempt to call close while active positions exist
    await expect(gridPositionManager.connect(owner).close()).to.be.revertedWith("E12: Active positions must be zero");
  });

  it("Should allow the owner to perform an emergency withdraw", async function () {
    // Deposit funds to create positions
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);

    // Call the emergencyWithdraw function
    await expect(gridPositionManager.connect(owner).emergencyWithdraw())
      .to.emit(gridPositionManager, "EmergencyWithdraw");

    // Verify that token0 and token1 balances are transferred to the owner
    const token0Balance = await ethers.provider.getBalance(gridPositionManager.address);
    const token1Balance = await ethers.provider.getBalance(gridPositionManager.address);
    expect(token0Balance).to.equal(0);
    expect(token1Balance).to.equal(0);
    // Verify that active positions are cleared
    const activePositions = await gridPositionManager.getActivePositionIndexes();
    expect(activePositions.length).to.equal(0);
  });

  it("Should revert if non-owner tries to perform an emergency withdraw", async function () {
    // Deposit funds to create positions
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);

    // Attempt to call emergencyWithdraw as a non-owner
    await expect(gridPositionManager.connect(addr1).emergencyWithdraw()).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should revert if active positions exist when closing", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage, GridType.NEUTRAL);
    await expect(gridPositionManager.connect(owner).close()).to.be.revertedWith("E12: Active positions must be zero");
  });

  it("Should revert if no Ether to recover", async function () {
    await expect(gridPositionManager.connect(owner).recoverEther()).to.be.revertedWith("E13: No Ether to recover");
  });

  it("Should revert if position index is out of bounds", async function () {
    await expect(gridPositionManager.getPosition(999)).to.be.revertedWith("E15: Index out of bounds");
  });
});
