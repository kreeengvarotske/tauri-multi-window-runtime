using System;

// Statistics for Summarize-SymmetricRuns.ps1; tested by Test-SymmetricStats.ps1.
public static class SymmetricBenchStats {
    public static double Median(double[] values) {
        double[] sorted = (double[])values.Clone();
        Array.Sort(sorted);
        int n = sorted.Length;
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
    }

    // P(X <= k) for X ~ Binomial(n, 1/2).
    public static double BinomialHalfCdf(int n, int k) {
        if (k < 0) return 0.0;
        double term = Math.Pow(0.5, n), sum = 0.0;
        for (int i = 0; i <= Math.Min(k, n); i++) {
            sum += term;
            term = term * (n - i) / (i + 1);
        }
        return Math.Min(1.0, sum);
    }

    public static int CountZeros(double[] diffs) {
        int zeros = 0;
        foreach (double d in diffs) if (d == 0.0) zeros++;
        return zeros;
    }

    // Two-sided sign test of "median paired difference = 0" that keeps every difference in n:
    // zeros count as neither positive nor negative. If 0 is a median of the differences, then
    // P(d > 0) <= 1/2 and P(d < 0) <= 1/2, so each sign count is stochastically at most
    // Binomial(n, 1/2) and p = 2 min(P(X >= positives), P(X >= negatives)) is valid. It is exact
    // for continuous differences (it then equals the usual sign test) and conservative with zeros.
    public static double SignTestP(double[] diffs) {
        int n = diffs.Length, positive = 0, negative = 0;
        if (n == 0) return 1.0;
        foreach (double d in diffs) { if (d > 0) positive++; else if (d < 0) negative++; }
        double positiveTail = 1.0 - BinomialHalfCdf(n, positive - 1);
        double negativeTail = 1.0 - BinomialHalfCdf(n, negative - 1);
        return Math.Max(0.0, Math.Min(1.0, 2.0 * Math.Min(positiveTail, negativeTail)));
    }

    // Distribution-free closed interval for the median from order statistics over ALL differences
    // (zeros included): [d(k), d(n-k+1)] with the largest k such that P(X <= k-1) <= (1-level)/2.
    // Returns {low, high, minimum coverage}, or null when n is too small for the level.
    // The coverage 1 - 2 P(X <= k-1) is a guaranteed lower bound for any distribution, ties
    // included; it is exact only for continuous differences.
    public static double[] MedianInterval(double[] diffs, double level) {
        int n = diffs.Length;
        double tail = (1.0 - level) / 2.0;
        int k = 0;
        while (k + 1 <= n / 2 && BinomialHalfCdf(n, k) <= tail) k++;
        if (k == 0) return null;
        double[] sorted = (double[])diffs.Clone();
        Array.Sort(sorted);
        return new double[] { sorted[k - 1], sorted[n - k], 1.0 - 2.0 * BinomialHalfCdf(n, k - 1) };
    }
}
