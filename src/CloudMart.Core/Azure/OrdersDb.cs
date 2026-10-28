using CloudMart.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace CloudMart.Core.Azure;

/// <summary>One EF Core model, two engines: Azure SQL Database (SqlServer) or Azure Database for PostgreSQL.</summary>
public sealed class OrdersDbContext(DbContextOptions<OrdersDbContext> options) : DbContext(options)
{
    public DbSet<Order> Orders => Set<Order>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
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
}

public sealed class EfOrderRepository(OrdersDbContext db) : IOrderRepository, IHealthProbe
{
    public string Name => "orders-database";

    public async Task AddAsync(Order order, CancellationToken ct = default)
    {
        db.Orders.Add(order);
        await db.SaveChangesAsync(ct);
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
