using CloudMart.Core;
using CloudMart.Core.Payments;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace CloudMart.Payments;

/// <summary>The Payments database: its own database, not a table in the orders database (database per service).</summary>
public sealed class PaymentsDbContext(DbContextOptions<PaymentsDbContext> options) : DbContext(options)
{
    public DbSet<Payment> Payments => Set<Payment>();

    protected override void OnModelCreating(ModelBuilder modelBuilder) =>
        modelBuilder.Entity<Payment>(payment =>
        {
            // Mirrors CreateLedgerTableSql below; EF uses it for parameter types, not to create the table.
            payment.ToTable("Payments");
            payment.HasKey(p => p.Id);
            payment.Property(p => p.Id).HasMaxLength(32);
            payment.Property(p => p.IdempotencyKey).HasMaxLength(100);
            payment.Property(p => p.CustomerId).HasMaxLength(128);
            payment.Property(p => p.Currency).HasMaxLength(3);
            payment.Property(p => p.Status).HasConversion<string>().HasMaxLength(20);
            payment.Property(p => p.Reason).HasMaxLength(500);
            payment.Property(p => p.GatewayReference).HasMaxLength(40);
            payment.Property(p => p.Amount).HasPrecision(18, 2);
        });

    /// <summary>
    /// An *updatable ledger table*: SQL Server keeps a cryptographically chained history of every insert and update,
    /// so an administrator can't quietly rewrite a payment. EF Core can't declare LEDGER = ON, so the DDL is by hand.
    /// Check it in the portal's query editor:
    ///   SELECT * FROM dbo.Payments_Ledger ORDER BY ledger_transaction_id;   -- full history, including refunds
    ///   EXECUTE sys.sp_verify_database_ledger_from_digest_storage;          -- tamper check (needs digest storage)
    /// </summary>
    public const string CreateLedgerTableSql = """
        IF OBJECT_ID(N'dbo.Payments', N'U') IS NULL
        CREATE TABLE dbo.Payments
        (
            Id nvarchar(32) NOT NULL CONSTRAINT PK_Payments PRIMARY KEY,
            IdempotencyKey nvarchar(100) NOT NULL CONSTRAINT UQ_Payments_IdempotencyKey UNIQUE,
            OrderId uniqueidentifier NOT NULL CONSTRAINT UQ_Payments_OrderId UNIQUE,
            CustomerId nvarchar(128) NOT NULL,
            Amount decimal(18, 2) NOT NULL,
            Currency nvarchar(3) NOT NULL,
            Status nvarchar(20) NOT NULL,
            Reason nvarchar(500) NULL,
            GatewayReference nvarchar(40) NULL,
            CreatedUtc datetimeoffset NOT NULL,
            UpdatedUtc datetimeoffset NOT NULL
        )
        WITH (SYSTEM_VERSIONING = ON, LEDGER = ON);
        """;
}

public sealed class LedgerPaymentStore(PaymentsDbContext db) : IPaymentStore, IHealthProbe
{
    public string Name => "payments-database";

    public Task<Payment?> GetAsync(string id, CancellationToken ct = default) =>
        db.Payments.AsNoTracking().FirstOrDefaultAsync(p => p.Id == id, ct);

    public Task<Payment?> GetByIdempotencyKeyAsync(string key, CancellationToken ct = default) =>
        db.Payments.AsNoTracking().FirstOrDefaultAsync(p => p.IdempotencyKey == key, ct);

    public Task<Payment?> GetByOrderAsync(Guid orderId, CancellationToken ct = default) =>
        db.Payments.AsNoTracking().FirstOrDefaultAsync(p => p.OrderId == orderId, ct);

    public async Task<bool> TryAddAsync(Payment payment, CancellationToken ct = default)
    {
        db.Payments.Add(payment);
        try
        {
            await db.SaveChangesAsync(ct);
            return true;
        }
        catch (DbUpdateException ex) when (ex.InnerException is SqlException { Number: 2627 or 2601 })
        {
            // A UNIQUE constraint fired: a concurrent attempt with the same key or order got there first.
            db.ChangeTracker.Clear();
            return false;
        }
    }

    public async Task<bool> TryRefundAsync(string id, string reason, CancellationToken ct = default)
    {
        var now = DateTimeOffset.UtcNow;
        // On a ledger table an UPDATE keeps the old row version in the ledger history: the refund can't erase the charge.
        var rows = await db.Payments
            .Where(p => p.Id == id && p.Status == PaymentStatus.Captured)
            .ExecuteUpdateAsync(s => s
                .SetProperty(p => p.Status, PaymentStatus.Refunded)
                .SetProperty(p => p.Reason, reason)
                .SetProperty(p => p.UpdatedUtc, now), ct);
        return rows == 1;
    }

    public Task CheckAsync(CancellationToken ct) => db.Database.ExecuteSqlRawAsync("SELECT TOP (1) Id FROM dbo.Payments", ct);
}
