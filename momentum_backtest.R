# MOMENTUM STRATEGY BACKTEST (monthly rebalancing)
# My idea: at the end of each month, this program rank stocks by how well they did over the past year (ignoring the most recent month), buys the top few, and holds them for ONE month, then repeat. Compared against the S&P 500.
# The one rule that keeps this honest: each month's choice uses ONLY prices from the past. We then look at what happened NEXT month.

# Packages I'm Using 
library(tidyquant)   # downloads stock prices
library(readr)       # reads and writes CSV files
library(tidyr)       # reshapes tables
library(lubridate)   # works with dates
library(ggplot2)     # charts
library(dplyr)       # data wrangling. Load this LAST so its functions win any name clashes


# A fixed list of 40 large U.S. companies. I chose these from S&P 500 data as mostly big companies in 2015 that still trade today (the metirc is market capitalization) 
tickers <- c("AAPL", "XOM", "MSFT", "GOOGL", "JNJ", "WFC", "WMT", "JPM",
             "AMZN", "PG", "META", "VZ", "PFE", "KO", "CVX", "ORCL",
             "MRK", "DIS", "CSCO", "V", "HD", "INTC", "CMCSA", "PM",
             "MCD", "UNH", "GILD", "BAC", "C", "PEP", "AMGN", "MO",
             "CVS", "BMY", "BA", "UNP", "TXN", "MDT", "LOW", "ABT")

benchmark  <- "SPY"          # an S&P 500 fund, used as the comparison
start_date <- "2014-12-01"   # earlier than the backtest, because the ranking needs about a year of history
end_date   <- "2025-12-31"

lookback       <- 12      # rank the stocks on their return over the last 12 months...
skip           <- 1       # but ignores the most recent 1 month
top_n          <- 8       # how many stocks to hold (the top fifth of 40)
cost_per_trade <- 0.001   # 0.1% cost every time we buy or sell something


# Getting the Prices
# The first run downloads the data and saves a copy on my computer.
# After that it reuses the saved copy, so it doesn't depend on Yahoo.
cache_file <- "prices_raw.csv"

if (file.exists(cache_file)) {
  prices <- read_csv(cache_file, show_col_types = FALSE)
} else {
  prices <- tq_get(c(tickers, benchmark), get = "stock.prices",
                   from = start_date, to = end_date)
  write_csv(prices, cache_file)
}

# "adjusted" is the price corrected for splits and dividends, so returns
# computed from it are true total returns.
prices <- prices %>% filter(!is.na(adjusted))

not_downloaded <- setdiff(c(tickers, benchmark), unique(prices$symbol))
if (length(not_downloaded) > 0) {
  warning("These tickers did not download: ", paste(not_downloaded, collapse = ", "),
          ". Delete prices_raw.csv, wait a few minutes, and run again.")
}
if (!(benchmark %in% prices$symbol)) {
  stop("The benchmark (SPY) did not download. Delete prices_raw.csv, wait a few minutes, and run again.")
}


# (dplyr:: tells R exactly which package's last() to use.)
monthly <- prices %>%
  arrange(symbol, date) %>%
  mutate(month = floor_date(date, "month")) %>%
  group_by(symbol, month) %>%
  summarise(price = dplyr::last(adjusted), .groups = "drop")

# momentum = return over a 12-month window that ended 1 month ago.
#            It uses only prices from the PAST.
# next_ret = what the stock earns over the NEXT month (this is the
#            result we are testing; it is never used to choose stocks).
monthly <- monthly %>%
  arrange(symbol, month) %>%
  group_by(symbol) %>%
  mutate(
    momentum = dplyr::lag(price, skip) / dplyr::lag(price, skip + lookback) - 1,
    next_ret = dplyr::lead(price, 1) / price - 1
  ) %>%
  ungroup()

stocks <- monthly %>% filter(symbol != benchmark)    # SPY is the benchmark, not a candidate

picks <- stocks %>%
  filter(!is.na(momentum), !is.na(next_ret)) %>%
  group_by(month) %>%
  slice_max(momentum, n = top_n, with_ties = FALSE) %>%
  ungroup()

# Equal-weight portfolio: average the next-month return of the picked stocks.
strategy <- picks %>%
  group_by(month) %>%
  summarise(gross = mean(next_ret), .groups = "drop")

# Turnover = share of the portfolio that is NEW this month.
# (1 means we replaced everything, 0 means we kept every stock.)
months_list <- strategy$month
turnover    <- numeric(length(months_list))
previous    <- character(0)

for (i in seq_along(months_list)) {
  current     <- picks$symbol[picks$month == months_list[i]]
  turnover[i] <- length(setdiff(current, previous)) / top_n
  previous    <- current
}

# Each replaced stock is sold (cost) and a new one bought (cost).
# This slightly overstates the cost of the very first month; that's fine.
strategy$turnover <- turnover
strategy$net      <- strategy$gross - strategy$turnover * 2 * cost_per_trade


# (a) The S&P 500 fund
spy <- monthly %>%
  filter(symbol == benchmark) %>%
  select(month, spy = next_ret)

# (b) Simply owning ALL the stocks on our list, equal weight.
# If momentum can't beat this, then the ranking isn't adding anything.
universe <- stocks %>%
  filter(!is.na(next_ret)) %>%
  group_by(month) %>%
  summarise(equal_weight = mean(next_ret), .groups = "drop")

results <- strategy %>%
  select(month, strategy_net = net, strategy_gross = gross, turnover) %>%
  left_join(spy, by = "month") %>%
  left_join(universe, by = "month") %>%
  drop_na()

cat("Months in backtest:", nrow(results), "\n")
cat("Stocks in the list:", n_distinct(stocks$symbol), "\n")
cat("Average monthly turnover:", round(mean(results$turnover) * 100), "% of the portfolio\n\n")

summarize_returns <- function(r, name) {
  growth     <- cumprod(1 + r)                    # value of $1 over time
  years      <- length(r) / 12
  ann_return <- tail(growth, 1)^(1 / years) - 1   # average yearly growth rate
  ann_vol    <- sd(r) * sqrt(12)                  # yearly volatility (ups and downs)
  peak       <- cummax(c(1, growth))[-1]          # highest value reached so far
  drawdown   <- growth / peak - 1                 # how far below the peak we are

  tibble(
    portfolio             = name,
    total_return_pct      = (tail(growth, 1) - 1) * 100,
    annual_return_pct     = ann_return * 100,
    annual_volatility_pct = ann_vol * 100,
    return_per_risk       = ann_return / ann_vol,
    worst_drop_pct        = min(drawdown) * 100
  )
}

summary_table <- bind_rows(
  summarize_returns(results$strategy_net,   "Momentum (after costs)"),
  summarize_returns(results$strategy_gross, "Momentum (before costs)"),
  summarize_returns(results$equal_weight,   "Whole stock list, equal weight"),
  summarize_returns(results$spy,            "S&P 500 (SPY)")
)

print(summary_table %>% mutate(across(where(is.numeric), ~ round(.x, 2))), width = Inf)

growth_long <- results %>%
  transmute(
    month,
    `Momentum (after costs)` = cumprod(1 + strategy_net),
    `Whole stock list`       = cumprod(1 + equal_weight),
    `S&P 500 (SPY)`          = cumprod(1 + spy)
  ) %>%
  pivot_longer(-month, names_to = "portfolio", values_to = "value_of_1_dollar")

chart <- ggplot(growth_long, aes(x = month, y = value_of_1_dollar, color = portfolio)) +
  geom_line(linewidth = 1) +
  labs(
    title    = "Growth of $1: momentum strategy vs. benchmarks",
    subtitle = "Monthly rebalancing, 2016-2025\nStock list uses only companies that still trade today, which can bias results",    x        = NULL,
    y        = "Value of $1 invested",
    color    = NULL
  ) +
  theme_minimal()

print(chart)

ggsave("momentum_vs_spy.png", chart, width = 9, height = 5, dpi = 150)
write_csv(results, "backtest_results.csv")
write_csv(summary_table, "performance_summary.csv")
cat("\nSaved: momentum_vs_spy.png, backtest_results.csv, performance_summary.csv\n")
