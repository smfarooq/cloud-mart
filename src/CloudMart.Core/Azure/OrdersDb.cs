using CloudMart.Core.Domain;
using CloudMart.Core.Outbox;
using Microsoft.EntityFrameworkCore;

namespace CloudMart.Core.Azure;

/// <summary>One EF Core model, two engines: Azure SQL Database (SqlServer) or Azure Database for PostgreSQL.</summary>
public sealed class OrdersDbContext(DbContextOptions<OrdersDbContext> options) : DbContext(options)
{
    public DbSet<Order> Orders => Set<Order>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<OutboxMessage>(message =>
        {
            // Mirrors CreateOutboxTableSql below. EnsureCreated skips it: the DDL is the one definition of the table.
            message.ToTable("OutboxMessages", table => table.ExcludeFromMigrations());
            message.HasKey(m => m.Id);
            message.Property(m => m.Type).HasMaxLength(100);
            message.Property(m => m.TraceParent).HasMaxLength(55);
            message.Property(m => m.LastError).HasMaxLength(OutboxMessage.MaxErrorLength);
        });

        modelBuilder.Entity<Order>(order =>
        {
            order.ToTable("Orders");
            order.HasKey(o => o.Id);
            order.Property(o => o.CustomerId).HasMaxLength(128).IsRequired();
            order.Property(o => o.CustomerName).HasMaxLength(200);
            order.Property(o => o.Status).HasConversion<string>().HasMaxLength(20);
            order.Property(o => o.StatusReason).HasMaxLength(500);
            order.Property(o => o.Total).HasPrecision(18, 2);
            order.Property(o => o.PaymentId).HasMaxLength(40);
            order.Property(o => o.TrackingNumber).HasMaxLength(40);
            order.HasIndex(o => new { o.CustomerId, o.CreatedUtc });

            order.OwnsMany(o => o.Lines, line =>
            {
                line.ToTable("OrderLines");
                line.WithOwner().HasForeignKey("OrderId");
                line.Property<int>("Id");
                line.HasKey("Id");
                line.Property(l => l.ProductId).HasMaxLength(64);
                line.Property(l => l.ProductName).HasMaxLength(200);
                line.Property(l => l.UnitPrice).HasPrecision(18, 2);
            });
        });
    }

    /// <summary>
    /// The outbox table, created at startup after EnsureCreated. EnsureCreated builds the schema only in an empty
    /// database, so it would never add this table to a lab database that already has orders. "If not exists" DDL
    /// works for both. The filtered index holds only unsent rows, which is all the relay ever asks about.
    /// </summary>
    public string CreateOutboxTableSql => Database.IsNpgsql()
        ? """
          CREATE TABLE IF NOT EXISTS "OutboxMessages"
          (
              "Id" uuid NOT NULL CONSTRAINT "PK_OutboxMessages" PRIMARY KEY,
              "Type" character varying(100) NOT NULL,
              "Payload" text NOT NULL,
              "TraceParent" character varying(55) NULL,
              "CreatedUtc" timestamp with time zone NOT NULL,
              "NextAttemptUtc" timestamp with time zone NOT NULL,
              "Attempts" integer NOT NULL,
              "ClaimId" uuid NULL,
              "SentUtc" timestamp with time zone NULL,
              "LastError" character varying(1000) NULL
          );
          CREATE INDEX IF NOT EXISTS "IX_OutboxMessages_Due" ON "OutboxMessages" ("NextAttemptUtc") WHERE "SentUtc" IS NULL;
          """
        : """
          IF OBJECT_ID(N'dbo.OutboxMessages', N'U') IS NULL
          BEGIN
              CREATE TABLE dbo.OutboxMessages
              (
                  Id uniqueidentifier NOT NULL CONSTRAINT PK_OutboxMessages PRIMARY KEY,
                  Type nvarchar(100) NOT NULL,
                  Payload nvarchar(max) NOT NULL,
                  TraceParent nvarchar(55) NULL,
                  CreatedUtc datetimeoffset NOT NULL,
                  NextAttemptUtc datetimeoffset NOT NULL,
                  Attempts int NOT NULL,
                  ClaimId uniqueidentifier NULL,
                  SentUtc datetimeoffset NULL,
                  LastError nvarchar(1000) NULL
              );
              CREATE INDEX IX_OutboxMessages_Due ON dbo.OutboxMessages (NextAttemptUtc) WHERE SentUtc IS NULL;
          END
          """;
}

public sealed class EfOrderRepository(OrdersDbContext db) : IOrderRepository, IHealthProbe
{
    public string Name => "orders-database";

    public async Task AddAsync(Order order, OutboxMessage placed, CancellationToken ct = default)
    {
        // One SaveChanges is one transaction: both rows are committed, or neither is.
        db.Orders.Add(order);
        db.OutboxMessages.Add(placed);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch
        {
            // Don't leave the failed rows tracked: the caller may use this context again (a raced Idempotency-Key).
            db.ChangeTracker.Clear();
            throw;
        }
    }

    public Task<Order?> GetAsync(Guid id, CancellationToken ct = default) =>
        db.Orders.AsNoTracking().FirstOrDefaultAsync(o => o.Id == id, ct);

    public async Task<IReadOnlyList<Order>> ListByCustomerAsync(string customerId, int take, CancellationToken ct = default) =>
        await db.Orders.AsNoTracking()
            .Where(o => o.CustomerId == customerId)
            .OrderByDescending(o => o.CreatedUtc)
            .Take(take)
            .ToListAsync(ct);

    public async Task<IReadOnlyList<Order>> ListRecentAsync(int take, CancellationToken ct = default) =>
        await db.Orders.AsNoTracking().OrderByDescending(o => o.CreatedUtc).Take(take).ToListAsync(ct);

    public async Task<bool> TryCompleteAsync(Guid id, OrderOutcome outcome, CancellationToken ct = default)
    {
        var now = DateTimeOffset.UtcNow;
        // A conditional UPDATE ... WHERE Status = 'Pending' makes the state change atomic and idempotent.
        var rows = await db.Orders
            .Where(o => o.Id == id && o.Status == OrderStatus.Pending)
            .ExecuteUpdateAsync(s => s
                .SetProperty(o => o.Status, outcome.Status)
                .SetProperty(o => o.StatusReason, outcome.Reason)
                .SetProperty(o => o.PaymentId, outcome.PaymentId)
                .SetProperty(o => o.TrackingNumber, outcome.TrackingNumber)
                .SetProperty(o => o.ReviewRequired, o => o.ReviewRequired || outcome.ReviewRequired)
                .SetProperty(o => o.UpdatedUtc, now), ct);
        return rows == 1;
    }

    public Task MarkForReviewAsync(Guid id, CancellationToken ct = default) =>
        db.Orders.Where(o => o.Id == id).ExecuteUpdateAsync(s => s.SetProperty(o => o.ReviewRequired, true), ct);

    public async Task<OrderSummary> SummarizeAsync(DateTimeOffset since, CancellationToken ct = default)
    {
        var rows = await db.Orders.AsNoTracking()
            .Where(o => o.CreatedUtc >= since)
            .GroupBy(o => o.Status)
            .Select(g => new { Status = g.Key, Count = g.Count(), Revenue = g.Sum(o => o.Total) })
            .ToListAsync(ct);

        int CountOf(OrderStatus status) => rows.Where(r => r.Status == status).Sum(r => r.Count);
        return new OrderSummary(
            rows.Sum(r => r.Count),
            CountOf(OrderStatus.Pending),
            CountOf(OrderStatus.Confirmed),
            CountOf(OrderStatus.Rejected),
            rows.Where(r => r.Status == OrderStatus.Confirmed).Sum(r => r.Revenue));
    }

    // A real query rather than CanConnectAsync, so the readiness probe surfaces the actual error
    // (firewall, DNS, "Login failed for user '<token-identified principal>'", ...).
    public Task CheckAsync(CancellationToken ct) => db.Database.ExecuteSqlRawAsync("SELECT 1", ct);
}

/// <summary>The outbox table in the orders database, shared by every API instance's relay.</summary>
public sealed class EfOutboxStore(OrdersDbContext db) : IOutboxStore
{
    public async Task<bool> EnsureAsync(OutboxMessage message, CancellationToken ct = default)
    {
        if (await db.OutboxMessages.AnyAsync(m => m.Id == message.Id, ct))
            return false;

        db.OutboxMessages.Add(message);
        try
        {
            await db.SaveChangesAsync(ct);
            return true;
        }
        catch (DbUpdateException)
        {
            // A concurrent retry inserted it first: a primary-key violation, whatever the provider calls it.
            db.ChangeTracker.Clear();
            if (await db.OutboxMessages.AnyAsync(m => m.Id == message.Id, ct))
                return false;
            throw;
        }
    }

    public async Task<IReadOnlyList<OutboxMessage>> ClaimAsync(int max, DateTimeOffset now, TimeSpan lease, CancellationToken ct = default)
    {
        var claimId = Guid.NewGuid();
        var leaseUntil = now + lease;

        // One statement picks the due rows and leases them, skipping rows another relay's claim has locked right now
        // (READPAST, SKIP LOCKED) instead of waiting for them. The lease keeps the rows away from other relays after
        // the statement commits, while this relay publishes.
        var claimed = db.Database.IsNpgsql()
            ? db.OutboxMessages.FromSql($"""
                WITH due AS (
                    SELECT "Id" FROM "OutboxMessages"
                    WHERE "SentUtc" IS NULL AND "NextAttemptUtc" <= {now}
                    ORDER BY "NextAttemptUtc"
                    LIMIT {max}
                    FOR UPDATE SKIP LOCKED)
                UPDATE "OutboxMessages" AS m
                SET "ClaimId" = {claimId}, "NextAttemptUtc" = {leaseUntil}
                FROM due
                WHERE m."Id" = due."Id"
                RETURNING m.*
                """)
            : db.OutboxMessages.FromSql($"""
                WITH due AS (
                    SELECT TOP ({max}) * FROM dbo.OutboxMessages WITH (ROWLOCK, UPDLOCK, READPAST)
                    WHERE SentUtc IS NULL AND NextAttemptUtc <= {now}
                    ORDER BY NextAttemptUtc)
                UPDATE due
                SET ClaimId = {claimId}, NextAttemptUtc = {leaseUntil}
                OUTPUT inserted.*
                """);

        var messages = await claimed.AsNoTracking().ToListAsync(ct);
        return messages.OrderBy(m => m.CreatedUtc).ToList();
    }

    public Task MarkSentAsync(Guid id, DateTimeOffset sentUtc, CancellationToken ct = default) =>
        db.OutboxMessages
            .Where(m => m.Id == id && m.SentUtc == null)
            .ExecuteUpdateAsync(s => s
                .SetProperty(m => m.SentUtc, sentUtc)
                .SetProperty(m => m.ClaimId, (Guid?)null), ct);

    public Task RetryLaterAsync(Guid id, Guid claimId, DateTimeOffset retryUtc, string error, CancellationToken ct = default) =>
        db.OutboxMessages
            .Where(m => m.Id == id && m.ClaimId == claimId && m.SentUtc == null)
            .ExecuteUpdateAsync(s => s
                .SetProperty(m => m.ClaimId, (Guid?)null)
                .SetProperty(m => m.NextAttemptUtc, retryUtc)
                .SetProperty(m => m.Attempts, m => m.Attempts + 1)
                .SetProperty(m => m.LastError, error), ct);

    public Task<DateTimeOffset?> NextDueAsync(CancellationToken ct = default) =>
        db.OutboxMessages.Where(m => m.SentUtc == null).MinAsync(m => (DateTimeOffset?)m.NextAttemptUtc, ct);
}
