
/*
GRUPO D: 
Ana Martins - 20242039
Antonio Crespo - 20242034
João Manso - 20242194
Pedro Matos - 20242053
*/

-- PARTE I -- 
Use AdventureWorks

IF NOT EXISTS (
	SELECT * FROM sys.schemas WHERE name = 'Auction'
)
BEGIN
	EXEC('CREATE SCHEMA Auction')
END
GO

-- Auction Table
IF NOT EXISTS (
    SELECT * FROM sys.tables AS t
    JOIN sys.schemas AS s ON t.schema_id = s.schema_id
    WHERE s.name = 'Auction' AND t.name = 'AuctionTable'
)
BEGIN
	CREATE TABLE Auction.AuctionTable(
		AuctionID INT PRIMARY KEY IDENTITY(1,1),
		ProductID INT NOT NULL,
		InitialBidPrice MONEY NOT NULL,
		CurrentBid MONEY,
		Active BIT NOT NULL,
		Cancelled BIT DEFAULT 0,
		StartTime DATETIME NOT NULL DEFAULT GETDATE(),
		ExpireDate DATETIME DEFAULT DATEADD(DAY, 7, GETDATE()),
		FOREIGN KEY (ProductID) REFERENCES Production.Product(ProductID)
	);
END
GO


-- Bid Table
IF NOT EXISTS (
	SELECT * FROM sys.tables as t
	JOIN sys.schemas as s ON (t.schema_id = s.schema_id) 
	WHERE s.name = 'Auction' AND t.name = 'BidTable'
)
BEGIN
	CREATE TABLE Auction.BidTable(
		BidID INT PRIMARY KEY IDENTITY(1,1), 
		AuctionID INT NOT NULL,
		CustomerID INT NOT NULL,
		BidAmount money NOT NULL,
		BidDate DATETIME NOT NULL DEFAULT GETDATE(),
		FOREIGN KEY (AuctionID) REFERENCES Auction.AuctionTable(AuctionID),
		FOREIGN KEY (CustomerID) REFERENCES Sales.Customer(CustomerID)
	);
	END
GO

-- Winner Table
IF NOT EXISTS (
	SELECT * FROM sys.tables as t
	JOIN sys.schemas as s ON (t.schema_id = s.schema_id) 
	WHERE s.name = 'Auction' AND t.name = 'WinnerTable'
)
BEGIN
	CREATE TABLE Auction.WinnerTable(
		AuctionID int NOT NULL,
		BidID int NOT NULL,
		WinnerID int NOT NULL,
		FinalBid money NOT NULL,
		ConclusionDate datetime,
		FOREIGN KEY (BidID) REFERENCES Auction.BidTable(BidID), --Enforce foreign key relationships
		FOREIGN KEY (WinnerID) REFERENCES Sales.Customer(CustomerID) --Enforce foreign key relationships
	);
END
GO

-- Config Table
IF NOT EXISTS (
    SELECT * FROM sys.tables as t
    JOIN sys.schemas as s ON (t.schema_id = s.schema_id) 
    WHERE s.name = 'Auction' AND t.name = 'ConfigTable'
)
BEGIN
    CREATE TABLE Auction.ConfigTable (
        DefaultMinimumBidIncrement MONEY NOT NULL,
        DefaultStartBidDate DATETIME NOT NULL,
        DefaultEndBidDate DATETIME NOT NULL,
        InitialDiscountResaleProducts FLOAT NOT NULL,
        InitialDiscountOwnedProducts FLOAT NOT NULL, 
        MaxPriceFactor FLOAT NOT NULL
    );
END
GO

-- Set ConfigTable Table
SET NOCOUNT ON
IF NOT EXISTS (
    SELECT * FROM Auction.ConfigTable)
INSERT INTO Auction.ConfigTable (DefaultMinimumBidIncrement, DefaultStartBidDate, DefaultEndBidDate,
  InitialDiscountResaleProducts, InitialDiscountOwnedProducts, MaxPriceFactor)
VALUES (0.05, '2025-11-17', '2025-11-30', 0.75, 0.5, 1);

DROP INDEX IF EXISTS idx_ProductID ON Production.product; CREATE INDEX idx_ProductID ON Production.product(ProductID)  


DROP INDEX IF EXISTS idx_CustomerID ON Sales.Customer; CREATE INDEX idx_CustomerID ON Sales.Customer(CustomerID)

DROP INDEX IF EXISTS idx_BidID ON Auction.BidTable;  CREATE INDEX  idx_BidID ON Auction.BidTable(BidId)
GO


--Store Procedures
--1 uspAddProductToAuction - Para adicionar produtos ao leilao
IF OBJECT_ID('Auction.uspAddProductToAuction', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspAddProductToAuction;
GO

CREATE OR ALTER PROCEDURE Auction.uspAddProductToAuction
    @ProductID INT,
    @ExpireDate DATETIME = NULL,
    @InitialBidPrice MONEY = NULL
AS
BEGIN
    -- Check if the product exists and is active
    IF NOT EXISTS (
        SELECT 1 FROM Production.Product 
        WHERE ProductID = @ProductID 
        AND SellEndDate IS NULL 
        AND DiscontinuedDate IS NULL
    )
    BEGIN
        RAISERROR('Product does not exist or is not active.', 16, 1);
        RETURN;
    END
    
    -- Check if the product is already in auction
    IF EXISTS (SELECT 1 FROM Auction.AuctionTable WHERE ProductID = @ProductID AND Active = 1)
    BEGIN
        RAISERROR('This product is already in auction.', 16, 1);
        RETURN;
    END
    
	-- Check if the product has a list price greater than zero
IF NOT EXISTS (
    SELECT 1 FROM Production.Product 
    WHERE ProductID = @ProductID 
    AND ListPrice > 0
)
BEGIN
    -- Simply return without adding the product to auction
    RETURN;
END

	IF @ExpireDate IS NULL
BEGIN
    SET @ExpireDate = DATEADD(DAY, 7, GETDATE());
    IF @ExpireDate < DATEADD(DAY, 7, '2025-11-29')
    BEGIN
        SET @ExpireDate = '2025-11-29';
    END
END

DECLARE @MaxDate DATETIME = '2025-11-29';
    IF @ExpireDate > @MaxDate
    BEGIN
        SET @ExpireDate = @MaxDate;
	END

    -- Get product data and configuration settings
    DECLARE @ListPrice MONEY, @MakeFlag BIT;
    DECLARE @ResaleDiscount FLOAT, @OwnedDiscount FLOAT;
    
    -- Get product data
    SELECT @ListPrice = ListPrice, @MakeFlag = MakeFlag
    FROM Production.Product
    WHERE ProductID = @ProductID;
    
    -- Get configuration settings
    Select
        @ResaleDiscount = InitialDiscountResaleProducts,
        @OwnedDiscount = InitialDiscountOwnedProducts
    FROM Auction.ConfigTable;
        
    BEGIN
        -- MakeFlag = 0: resale product
        -- MakeFlag = 1: owned product
        SET @InitialBidPrice = @ListPrice * 
            CASE WHEN @MakeFlag = 0 THEN @ResaleDiscount
                 ELSE @OwnedDiscount END;
    END
    
    -- Insert the auction
    INSERT INTO Auction.AuctionTable (
        ProductID, InitialBidPrice, CurrentBid, Active, StartTime, ExpireDate
    ) VALUES (
        @ProductID, @InitialBidPrice, NULL, 1, GETDATE(), @ExpireDate
    );
    
    SELECT 
        @ProductID AS ProductID,
        @InitialBidPrice AS InitialBidPrice,
        @ExpireDate AS ExpireDate;
END
GO


CREATE OR ALTER PROCEDURE Auction.uspTryBidProduct

    @ProductID INT,
    @CustomerID INT,
    @BidAmount MONEY 
AS
BEGIN
    DECLARE @AuctionID INT;
    DECLARE @CurrentBid MONEY;
    DECLARE @MinimumIncrement MONEY;
    DECLARE @InitialBidPrice MONEY;
    DECLARE @MaxPriceFactor FLOAT;
    DECLARE @ListPrice MONEY;
    DECLARE @BidID INT;

   -- Note: there is no max incremment limit on the user is able to bid
   
   --Firstly, check whether the auctionID exists and is active and/or not cancelled
   SELECT TOP 1 @AuctionID = AuctionID FROM Auction.AuctionTable WHERE ProductID = @ProductID AND Active = 1 ORDER BY StartTime DESC;

    IF @AuctionID IS NULL
    BEGIN
        THROW 50001, 'Product must be in the active auction list, perhaps check again later', 1;
    END

   -- Then if it exists retrieve current bid, increment and configuration values  and the current AuctionID 
   SELECT  @CurrentBid = CurrentBid, @InitialBidPrice = InitialBidPrice  FROM Auction.AuctionTable  WHERE AuctionID = @AuctionID;
   SELECT @MinimumIncrement = DefaultMinimumBidIncrement, @MaxPriceFactor = MaxPriceFactor FROM Auction.ConfigTable;
   SELECT @ListPrice = ListPrice   FROM Production.Product    WHERE ProductID = @ProductID;

	--Check whether the customer exists or if it NULL
	IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
    THROW 50001, 'You have placed an invalid Customer ID.', 1;

    -- If BidAmount is not provided, use minimum increment
    IF @CurrentBid IS NULL AND @BidAmount <= @InitialBidPrice
    BEGIN
        THROW 50001, 'Please insert a greater value than initial limit.', 1;
    END

	-- If the user wrote a NULL bit, increment with initial bid or current bid
	IF @BidAmount < @CurrentBid + @MinimumIncrement 
	BEGIN
		DECLARE @ErrorMsg NVARCHAR(255);
		SET @ErrorMsg = 'Please insert a greater value than: ' 
			             + CAST(@CurrentBid + @MinimumIncrement AS NVARCHAR(50)) + '€';
		THROW 50001, @ErrorMsg, 1;
	END

	-- Ensure bid is not higher than allowed max factor
	IF @BidAmount > @ListPrice * @MaxPriceFactor
	BEGIN
		SET @ErrorMsg = 'Do you really want to pay more than the maximum price (' 
			             + CAST(@ListPrice * @MaxPriceFactor AS NVARCHAR(50)) 
				         + '€)? Please insert a lower bid.';
		THROW 50001, @ErrorMsg, 1;
	END

    -- Ensure bid is not higher than allowed max factor
	IF @BidAmount > @ListPrice * @MaxPriceFactor
	BEGIN
		SET @ErrorMsg = 'Do you really want to pay more than the maximum price (' 
                    + CAST(@ListPrice * @MaxPriceFactor AS NVARCHAR(50)) + '€)? Please insert a lower bid. ';
		THROW 50001, @ErrorMsg, 1;
	END

    -- Update the current bid in AuctionTable
    UPDATE Auction.AuctionTable
    SET CurrentBid = @BidAmount
    WHERE AuctionID = @AuctionID;

    -- Track the bid on the bid table
    INSERT INTO Auction.BidTable(AuctionID, CustomerID, BidAmount)
    VALUES (@AuctionID, @CustomerID, @BidAmount);

    -- Check if bid meets win condition
    IF @BidAmount = @ListPrice * @MaxPriceFactor  OR @BidAmount > (@ListPrice * @MaxPriceFactor) - @MinimumIncrement
    BEGIN
        PRINT 'Many congratulations! You have won the Auction!';
        SET @BidID = SCOPE_IDENTITY();

        INSERT INTO Auction.WinnerTable(AuctionID, BidID, WinnerID, FinalBid, ConclusionDate)
        VALUES (@AuctionID, @BidID, @CustomerID, @BidAmount, GETDATE());

        -- After designating the winner, close the bid on that product
        UPDATE Auction.AuctionTable
        SET Active = 0
        WHERE AuctionID = @AuctionID;
    END
END
GO


--3 uspRemoveProductFromAuction - To remove products from Auction
IF OBJECT_ID('Auction.uspRemoveProductFromAuction', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspRemoveProductFromAuction;
GO
CREATE PROCEDURE Auction.uspRemoveProductFromAuction
    @ProductID INT
AS
BEGIN
	-- Verify if product is active in auction
    IF EXISTS (SELECT 1 FROM Auction.AuctionTable WHERE ProductID = @ProductID AND Active = 1)
    BEGIN
        -- Mark auction as inactive and cancelled
		UPDATE Auction.AuctionTable 
		SET Active = 0, Cancelled=1 
		WHERE ProductID = @ProductID;
	END
	ELSE
	BEGIN
		PRINT 'Product is not in auction'
	END
END
GO

--EXEC Auction.uspRemoveProductFromAuction @ProductID = 522;
--Select * From Auction.AuctionTable;

--4 uspListBidsOffersHistory - List Bids by CustomerID and Date
IF OBJECT_ID('Auction.uspListBidsOffersHistory', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspListBidsOffersHistory;
GO

CREATE PROCEDURE Auction.uspListBidsOffersHistory
    @CustomerID INT,
    @StartTime DATETIME,
    @EndTime DATETIME,
    @Active BIT = 1  -- Default to fetching active auctions only
AS
BEGIN
    SET NOCOUNT ON;

    -- Return customer bid history based on activity status
    IF @Active = 1
    BEGIN
        -- Fetch only active auction bids
        SELECT b.BidID, b.AuctionID, b.BidAmount, b.BidDate, p.ProductID, p.InitialBidPrice, p.CurrentBid, p.ExpireDate
        FROM Auction.BidTable as b
        JOIN Auction.AuctionTable as p ON b.AuctionID = p.AuctionID
        WHERE b.CustomerID = @CustomerID
          AND b.BidDate BETWEEN @StartTime AND @EndTime
          AND p.Active = 1;
    END
    ELSE
    BEGIN
        -- Fetch all bids, including inactive auctions
        SELECT b.BidID, b.AuctionID, b.BidAmount, b.BidDate, p.ProductID, p.InitialBidPrice, p.CurrentBid, p.ExpireDate, 
               CASE WHEN p.Active = 0 THEN 'Cancelled' ELSE 'Finished' END AS Status
        FROM Auction.BidTable b
        LEFT JOIN Auction.AuctionTable p ON b.AuctionID = p.AuctionID
        WHERE b.CustomerID = @CustomerID
          AND b.BidDate BETWEEN @StartTime AND @EndTime;
    END
END
GO

--5 uspUpdateProductAuctionStatus - To update the auction status for all auctioned products
IF OBJECT_ID('Auction.uspUpdateProductAuctionStatus', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspUpdateProductAuctionStatus;
GO
CREATE PROCEDURE Auction.uspUpdateProductAuctionStatus
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        --  Update to Active = 0 when they have expired and assign a winner of the current highest bidder
        UPDATE Auction.AuctionTable
        SET Active = 0
        WHERE ExpireDate < GETDATE() --Where ExpireDate = ExpireDate 
        AND Active = 1;

		INSERT INTO Auction.WinnerTable(AuctionID, BidID, WinnerID, FinalBid, ConclusionDate)
		SELECT ranked.AuctionID, ranked.BidID, ranked.CustomerID, ranked.BidAmount, ranked.ExpireDate
		FROM (
			SELECT  
				bids.AuctionID,
				bids.BidID,
				bids.CustomerID,
				bids.BidAmount,
				auction.ExpireDate,
				RANK() OVER (PARTITION BY bids.AuctionID ORDER BY bids.BidAmount DESC) AS rankofbid
				FROM Auction.BidTable as bids                      
				JOIN Auction.AuctionTable  as auction ON bids.AuctionID = auction.AuctionID
				WHERE auction.Active = 0) 
				as ranked WHERE rankofbid = 1

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

--PARTE II--

-- Clear any existing temporary tables
IF OBJECT_ID('tempdb..#Top30StoreCustomers') IS NOT NULL
    DROP TABLE #Top30StoreCustomers;
IF OBJECT_ID('tempdb..#Top30StoreCities') IS NOT NULL
    DROP TABLE #Top30StoreCities;
IF OBJECT_ID('tempdb..#TopOnlineCities') IS NOT NULL
    DROP TABLE #TopOnlineCities;
IF OBJECT_ID('tempdb..#RecommendedCities') IS NOT NULL
    DROP TABLE #RecommendedCities;

-- Step 1: Identify the top 30 customers FROM PHYSICAL STORES (by total purchase value) in the USA
SELECT TOP 30
    soh.CustomerID,
    SUM(soh.TotalDue) AS TotalSpent
INTO #Top30StoreCustomers
FROM Sales.SalesOrderHeader as soh 
JOIN Person.BusinessEntityAddress as be ON be.BusinessEntityID = soh.CustomerID
JOIN Person.Address as a ON be.AddressID = a.AddressID
JOIN Person.StateProvince as sp ON a.StateProvinceID = sp.StateProvinceID
JOIN Person.CountryRegion cr ON sp.CountryRegionCode = cr.CountryRegionCode
WHERE cr.Name = 'United States'
AND soh.OnlineOrderFlag = 0  -- Filter for physical stores only, not online
GROUP BY soh.CustomerID
ORDER BY SUM(soh.TotalDue) DESC;

-- Step 2: Identify the cities where these top 30 physical store customers are located
SELECT DISTINCT a.City
INTO #Top30StoreCities
FROM #Top30StoreCustomers t
JOIN Sales.SalesOrderHeader soh ON t.CustomerID = soh.CustomerID
JOIN Person.BusinessEntityAddress be ON be.BusinessEntityID = soh.CustomerID
JOIN Person.Address a ON be.AddressID = a.AddressID
JOIN Person.StateProvince sp ON a.StateProvinceID = sp.StateProvinceID
JOIN Person.CountryRegion cr ON sp.CountryRegionCode = cr.CountryRegionCode
WHERE cr.Name = 'United States';

-- Step 3: Identify the cities with the highest online sales revenue in the USA
-- Excluding the cities where the top 30 physical store customers are located
SELECT 
    a.City,
    SUM(soh.TotalDue) AS TotalRevenue
INTO #TopOnlineCities
FROM Sales.SalesOrderHeader as soh
JOIN Sales.Customer as c ON soh.CustomerID = c.CustomerID
JOIN Person.BusinessEntityAddress as be ON be.BusinessEntityID = c.CustomerID
JOIN Person.Address as a ON be.AddressID = a.AddressID
JOIN Person.StateProvince as sp ON a.StateProvinceID = sp.StateProvinceID
JOIN Person.CountryRegion as cr ON sp.CountryRegionCode = cr.CountryRegionCode
WHERE 
    cr.Name = 'United States'
    AND soh.OnlineOrderFlag = 1  -- We filter for online purchases
    AND a.City NOT IN (SELECT City FROM #Top30StoreCities)  -- We exclude the cities of the top physical store customers
	GROUP BY a.City;

-- Step 4: Select the 2 best cities to open physical stores
SELECT TOP 2
    City,
    TotalRevenue
INTO #RecommendedCities
FROM #TopOnlineCities
ORDER BY TotalRevenue DESC;

-- Display the recommended cities
SELECT * FROM #RecommendedCities;

-- Verify if any of the top 30 physical store customers are in these cities
-- (Should return 0 rows if our logic is correct)
SELECT 
    a.City,
    COUNT(DISTINCT t.CustomerID) AS TopCustomersCount
FROM #Top30StoreCustomers t
JOIN Sales.SalesOrderHeader soh ON t.CustomerID = soh.CustomerID
JOIN Person.BusinessEntityAddress be ON be.BusinessEntityID = soh.CustomerID
JOIN Person.Address a ON be.AddressID = a.AddressID
WHERE a.City IN (SELECT City FROM #RecommendedCities)
GROUP BY a.City;

-- Analyze existing customers in the recommended cities
-- Separated by purchase type (online/physical)
SELECT 
    a.City,
    CASE 
        WHEN soh.OnlineOrderFlag = 1 THEN 'Online'
        ELSE 'Physical Store'
    END AS OrderType,
    COUNT(DISTINCT soh.CustomerID) AS TotalCustomersCount,
    SUM(soh.TotalDue) AS TotalRevenue,
    AVG(soh.TotalDue) AS AverageOrderValue
FROM Sales.SalesOrderHeader soh
JOIN Person.BusinessEntityAddress be ON be.BusinessEntityID = soh.CustomerID
JOIN Person.Address a ON be.AddressID = a.AddressID
WHERE a.City IN (SELECT City FROM #RecommendedCities)
GROUP BY a.City, soh.OnlineOrderFlag;

-- Clean up temporary tables at the end
IF OBJECT_ID('tempdb..#Top30StoreCustomers') IS NOT NULL
    DROP TABLE #Top30StoreCustomers;
IF OBJECT_ID('tempdb..#Top30StoreCities') IS NOT NULL
    DROP TABLE #Top30StoreCities;
IF OBJECT_ID('tempdb..#TopOnlineCities') IS NOT NULL
    DROP TABLE #TopOnlineCities;
IF OBJECT_ID('tempdb..#RecommendedCities') IS NOT NULL
    DROP TABLE #RecommendedCities;
