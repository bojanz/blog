---
author: "Bojan Zivanovic"
date: 2020-09-25
title: Developing price and currency handling for Go
slug: "price-currency-handling-go"
---

Now that [bojanz/currency](https://github.com/bojanz/currency) is listed on [Awesome Go](https://awesome-go.com/), 
it's a good time to reflect on the ideas that made it a reality. Back in March I started using Go for a few side projects, 
and I ran into the need to represent and handle currency amounts (prices). After some research I realized that the 
ecosystem was missing a complete solution.

### What do we need?

Let's sketch out our requirements.

```c
type Amount struct {
	number       decimal
	currencyCode string
}

// Methods: NewAmount(), Add, Sub, Mul, Div, Round, Cmp...
```

- A currency amount consists of a decimal number and a currency code. 
- Trying to combine or compare amounts of different currencies returns an error. 
- Like time.Time, a currency.Amount has value semantics, which means that amounts are immutable. Adding amount A to amount B produces a third amount C instead of modifying B.
- The number and currencyCode are unexported to require usage of the appropriate methods.

We should be able to get basic information about a currency: numeric code, number of digits
(used for rounding), and symbol ($, £, €, etc).

We should be able to format an amount for display, getting "$10", "10 €", etc.
Formatting is locale specific, not currency specific ("10 €" for fr-CH, "€ 10" for de-CH).

### A decimal journey

Our first problem is that Go doesn't have a builtin type for decimal numbers.
Developers learn early on that [floats must never be used](https://husobee.github.io/money/float/2016/09/23/never-use-floats-for-currency.html) instead, because they are imprecise, 
and as amounts are multiplied, divided, rounded and summed up, those imprecisions add up, quickly becoming real business problems. 

An old and common workaround is to store the amount in its minor units (e.g. cents) as an integer, 
representing $5.99 as 599. But every trick has its cost. No amount can have sub-minor-unit precision (e.g. "5.884"), 
which is needed for certain kinds of products (e.g. selling in bulk) and in certain tax jurisdictions (e.g. EU VAT). 
Handling multiple currencies becomes more difficult, as different currencies have different numbers of decimals (JPY has 0, KWD has 3), 
making it harder to order by amount in the database.

Luckily, Go has two solid packages that implement decimals in userspace. The first one is [cockroachdb/apd](https://github.com/cockroachdb/apd).
It is well maintained and fast enough, solving our need. The API is not very friendly:
```c
// a + b = c
c := apd.New(0, 0)
ctx := apd.BaseContext.WithPrecision(16)
ctx.Add(c, a, b)

// round d to 2 decimals.
result := apd.New(0, 0)
ctx := apd.BaseContext.WithPrecision(16)
ctx.Rounding = apd.RoundHalfUp
ctx.Quantize(result, d, -2)
```
However, since we have our own methods for arithmetic and comparisons, we can wrap the apd logic, never even exposing
the underlying implementation to the user. We accept strings, and use them to instantiate the underlying type:
```
amount, _ := currency.NewAmount("20.99", "USD")
taxAmount, _ := amount.Mul("0.20")
// Methods use apd.NewFromString(n) to get a decimal.
```
This will also serve us well if we decide to switch the underlying decimal implementation, for example to [ericlagergren/decimal](https://github.com/ericlagergren/decimal) which is faster but has seen [instability](https://github.com/ericlagergren/decimal/issues/154) due to slower maintanance this year.

### Where do currencies come from?

Inflation happens, old currencies get deprecated, new currencies get introduced.
It pays off to generate currency data from an external source, so that new data
is always one `go generate` away. Currency codes and their numeric codes
can be retrieved from [ISO](https://www.currency-iso.org/dam/downloads/lists/list_one.xml). Locale-specific data, such as currency names, symbols,
formatting rules are taken from [CLDR](http://cldr.unicode.org/), a rare case of the entire industry cooperating on a common problem.

The problem with CLDR data is that there's megabytes of it, adding to binary sizes and memory usage. Let's try to reduce this weight.

The first trick is to reduce the number of locales for which data is generated. CLDR has 542 locales, but it is not likely that an application
will need to format prices in Church Slavic or Esperanto. Chrome uses an allowlist, while we opted for a denylist listing each ignored locale, allowing
community members to re-include a locale if they end up needing it.

The second trick is to stop shipping currency names, since they are rarely used on the backend and can be retrieved on the frontend.
Currencies tend to be identified by their code (USD) or their symbol ($), while currency names are usually left for certain lists in the UI.
With a few lines of javascript ([Intl.DisplayNames](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames)), the frontend can retrieve a localized currency name for each code.

The third trick is to deduplicate locales by parent, relying on the package performing locale fallback. 
If "fr-FR" and "fr" have the same data, "fr-FR" is removed, and the package selects "fr" instead.

Finaly, symbols are grouped, to reduce repetition:
```c
"CAD": {
	{"CA$", []string{"en"}},
	{"$", []string{"en-CA", "fr-CA"}},
	{"$CA", []string{"fa", "fr"}},
	{"C$", []string{"nl"}},
},
```

Our [gen.go](https://github.com/bojanz/currency/blob/master/gen.go) is 800 lines of scary code, but the result is worth it. The generated [data.go](https://github.com/bojanz/currency/blob/master/data.go) is only 30kb, adding around 128kb to binary size.

### Putting it all together

We now have an amount struct, formatting data, symbols. The final step is to create a formatter.

The formatter is about 200 lines of code long and respects locale-specific symbol positioning, grouping and decimal
separators, group sizes, numbering systems, etc. It has the full [set of options](https://github.com/bojanz/currency/blob/master/formatter.go#L40) offered by NumberFormatter APIs in
programming languages such as PHP, Java, Swift, etc.

```c
locale := currency.NewLocale("tr")
formatter := currency.NewFormatter(locale)
amount, _ := currency.NewAmount("1245.988", "EUR")
fmt.Println(formatter.Format(amount)) // €1.245,988

formatter.MaxDigits = 2
fmt.Println(formatter.Format(amount)) // €1.245,99

formatter.NoGrouping = true
fmt.Println(formatter.Format(amount)) // €1245,99

formatter.CurrencyDisplay = currency.DisplayCode
fmt.Println(formatter.Format(amount)) // EUR 1245,99

// Different numbering system.
amount, _ := currency.NewAmount("1234.59", "IRR")
locale := currency.NewLocale("fa")
formatter := currency.NewFormatter(locale)
fmt.Println(formatter.Format(amount)) // ‎ریال ۱٬۲۳۴٫۵۹
```

### Conclusion

With the right approach to data and the right set of constraints, we manage to solve currency handling with minimum cost
(~2500 lines of code, ~30kb of data). However, the use case would be greatly helped by Go having a decimal type
built in. I remain hopeful.





