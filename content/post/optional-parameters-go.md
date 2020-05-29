---
author: "Bojan Zivanovic"
date: 2020-05-29
title: Optional function parameters in Go
slug: "optional-parameters-go"
---

Unlike most languages used today, Go doesn't support optional function parameters. This was an intentional decision by the language creators:

_One feature missing from Go is that it does not support default function arguments. This was a deliberate
simplification. Experience tells us that defaulted arguments make it too easy to patch over API design flaws
by adding more arguments, resulting in too many arguments with interactions that are difficult to disentangle
or even understand. The lack of default arguments requires more functions or methods to be defined, as one
function cannot hold the entire interface, but that leads to a clearer API that is easier to understand.
Those functions all need separate names, too, which makes it clear which combinations exist, as well as
encouraging more thought about naming, a critical aspect of clarity and readability._
- [Rob Pike](https://talks.golang.org/2012/splash.article)

So, what does the Go ecosystem do instead? Let's take a look.

### Wrapper functions

Additional functions are defined which wrap the original function (possibly internal),
and provide defaults for one or more parameters. When possible, this results in a clearer API. 

A good example can be seen in the [strings](https://golang.org/pkg/strings/) package:
```c
// Replace returns a copy of the string s with the first n
// non-overlapping instances of old replaced by new.
// If n < 0, there is no limit on the number of replacements.
func Replace(s, old, new string, n int) string {}

// ReplaceAll returns a copy of the string s with all
// non-overlapping instances of old replaced by new.
func ReplaceAll(s, old, new string) string {
	return Replace(s, old, new, -1)
}
```
Callers can use strings.ReplaceAll() for the default use case, matching how the PHP and Python string replace functions work. For other use cases (e.g. replacing only the first occurence) there's strings.Replace() with the additional parameter.

However, sometimes a natural name for a wrapper isn't obvious. Imagine a password.Hash function with an optional cost parameter:
```
func Hash(password []byte, cost int) ([]byte, error)
```
How do we name the wrapper? HashDefault() doesn't sound friendly. We could flip the names, have Hash(password []byte) and a HashWithCost(password []byte, cost int), but that doesn't feel great either.

### Constants

The Hash() example isn't hypothetical, I took it from [x/crypto/bcrypt](https://godoc.org/golang.org/x/crypto/bcrypt):
```c
func GenerateFromPassword(password []byte, cost int) ([]byte, error)
```

The bcrypt package solves this by introducing a constant for the default cost:
```c
const DefaultCost int = 10
```

Thus, most callers use bcrypt like this:
```c
hash, err := bcrypt.GenerateFromPassword(password, bcrypt.DefaultCost)
```
The caller doesn't need to know what the default cost is. But it also can't ignore the existence of cost as a concept. This makes usage of this function more explicit, but creates potentially too much verbosity if there are multiple optional parameters.

Imagine an xmath.Round() function which allows you to specify the number of fraction digits (precision) and rounding mode:
```c
func Round(n float64, digits uint8, mode RoundingMode) float64
```
It is common for such a function to default to 0 digits, and to round up. With two constants, the call becomes:
```c
n = math.Round(n, xmath.DefaultDigits, xmath.RoundHalfUp)
```
That's becoming a mouthful. A possible solution would be to combine wrapper functions and constants, introducing a function per rounding mode:
```c
n = xmath.RoundHalfUp(n, xmath.DefaultDigits)
n = xmath.RoundHalfDown(n, xmath.DefaultDigits)
// RoundUp(), RoundDown(), RoundHalfEven(), RoundHalfOdd()...
```
This increases the surface area of the API. Instead of a single Round() function we now have half a dozen. To guide the caller we could have a Round() which passes through to RoundHalfUp(). However, godoc is alphabetical, so it will show Round() in the middle of the real rounding functions, making their relationship non-obvious.

My [bojanz/currency](https://github.com/bojanz/currency) package went for a simpler wrapper:
```c
// Round is a shortcut for RoundTo(currency.DefaultDigits, currency.RoundHalfUp).
func (a Amount) Round() Amount {
	return a.RoundTo(DefaultDigits, RoundHalfUp)
}

// RoundTo rounds a to the given number of fraction digits.
func (a Amount) RoundTo(digits uint8, mode RoundingMode) Amount {}
```
The DefaultDigits constant is a bit more magical here, indicating "use the currency-specific value",
e.g. 2 for USD and 0 for JPY. Callers use Round() by default, resorting to RoundTo() only if they
need to override one of the two parameters, which is less common (e.g. when calculating tax).

### Variadic functions

_One mitigating factor for the lack of default arguments is that Go has easy-to-use, type-safe support for variadic functions._
- Rob Pike

For functions with a single optional parameter, this is as close as Go gets to true optional parameters:
```c
// Can be called as Round(x) or Round(x, xmath.RoundHalfUp)
func Round(x float64, modes ...RoundingMode) float64 {
	mode := RoundHalfUp
	if len(modes) > 0 {
		mode = modes[0]
	}
}
```
The caller can now completely ignore the second parameter, at the expense of code clarity on the package side.
The function pretends to take between 0 and N rounding modes, even though only 1 is used.

Things become trickier if multiple optional parameters are needed. We now need to make sure each parameter is of a different type, and search for it in the passed slice by type.
There is an [example of such code](https://upspin.googlesource.com/upspin/+/master/errors/errors.go#123) in Rob Pike's Upspin project.
This makes the parameters both position-independent and optional, but results in unidiomatic code that is clearly fighting hard against the limitations of the language.

### Option structs

Optional parameters can be put on its own struct, which is then passed to the function. A nil struct can then be used to signal that defaults should be used.

Let's look at the [jpeg](https://golang.org/pkg/image/jpeg/) package:
```c
// Options are the encoding parameters.
// Quality ranges from 1 to 100 inclusive, higher is better.
type Options struct {
	Quality int
}

// Encode writes the Image m to w in JPEG 4:2:0 baseline format with the given
// options. Default parameters are used if a nil *Options is passed.
func Encode(w io.Writer, m image.Image, o *Options) error {}
```

The caller can then pass options:
```c
var buf bytes.Buffer
jpeg.Encode(&buf, m0, &jpeg.Options{Quality: 75})
```
or not:
```c
var buf bytes.Buffer
jpeg.Encode(&buf, m0, nil)
```

I am not a big fan of this approach. It requires using a pointer to options (which means
that the options can change underneath us). The caller still has to pass nil, and 
on second read guess what the nil means.

### Structs with options

Once there is a need to put options on a struct, why not attach the function itself to
that struct? The jpeg.Encode() function can become a jpeg.Encoder struct:
```c
type Encoder struct {
	Quality int
}

func NewEncoder() *Encoder {
	e := &Encoder{}
	e.Quality = 80
	return e
}

func (e *Encoder) Encode(w io.Writer, m image.Image) error {}
```

The default option can be modified after initializing the struct:
```c
var buf bytes.Buffer
encoder := jpeg.NewEncoder()
encoder.Quality = 90
encoder.Encode(&buf, m0)
```

A similar example is my own [currency.Formatter](https://github.com/bojanz/currency/blob/master/formatter.go#L35).

The benefit of this approach is that the constructor (NewEncoder) can set defaults for the
various options. The naked options can also be made private (requiring the use of a setter), or
manipulated using the [functional options pattern](https://dave.cheney.net/2014/10/17/functional-options-for-friendly-apis).

Note: The functional options pattern has a complexity cost and is often over-applied. Use it only
if options can solely be set at construct time (due to a network call being made with them, etc).

### Conclusion

It is my impression that not supporting optional parameters hasn't resulted in a better ecosystem.
Use cases for optional parameters will always exist, and package authors are forced to come up with their own workarounds,
many of which can be seen in the stdlib and its subrepositories. The cost of simplicity in the language
is paid by complexity in code.
