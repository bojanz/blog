---
author: "Bojan Zivanovic"
date: 2020-10-30
title: Developing address handling for Go
slug: "address-handling-go"
---

Web applications often need to handle postal addresses. We collect them from
users, validate and format them, send them to payment and shipping APIs.

Postal addresses are easy when limited to a single country. But each country has its
own rules on which fields are used and required, how they're labeled and validated.
A good widget, validator, formatter needs to take these rules into account.

Google has lead the way in solving this problem, defining and publishing 
[address data](https://chromium-i18n.appspot.com/ssl-address) on which language-specific
solutions can be built. Their solution, [libaddressinput](https://github.com/google/libaddressinput) for C++ and Java, is used
by Chrome and Android.

Five years ago I developed [commerceguys/addressing](https://github.com/commerceguys/addressing), which solved this problem for PHP.
It has since been downloaded over 4.5 million times and is used by many large applications
such as Concrete5, Drupal Commerce, Thelia.

Developing with Go, I ran into the same need again. I started using [Boostport/address](https://github.com/Boostport/address), and for a while all was well. 
I soon ran into the some of the same limitations I encountered while using commerceguys/addressing, the primary
one being the large size of the dataset, making it difficult to develop a decent JS component. I decided to iterate on the concept
one more time, re-evaluting old tradeoffs. Let me show you [bojanz/address](https://github.com/bojanz/address).

## Address struct

Let's start by defining a struct to hold our data.

```go
type Address struct {
	Line1 string
	Line2 string
	Line3 string
	// Sublocality is the neighborhood/suburb/district.
	Sublocality string
	// Locality is the city/village/post town.
	Locality string
	// Region is the state/province/prefecture.
	// An ISO code is used when available.
	Region string
	// PostalCode is the postal/zip/pin code.
	PostalCode string
	// CountryCode is the two-letter code as defined by CLDR.
	CountryCode string
}
```

Generic field names such as Locality have a long tradition, going back to OASIS and their [eXtensible Address Language (xAL)](http://www.oasis-open.org/committees/ciq/download.shtml) standard from almost two decades ago.
Brevity is a virtue so we use tweak those names, using Sublocality instead of DependentLocality and Region instead of AdministrativeArea. Both are common alternatives used by Google, [Schema.org](https://schema.org/PostalAddress) and others.

There are three line fields, matching the HTML5 autocomplete spec and many shipping APIs.
This leaves enough space for specifying an organization and department, house or hotel
name, and other similar "care of" use cases. When mapping to an API that only has two address lines,
Line3 can be appended to Line2, separated by a comma.

Recipient fields such as FirstName/LastName are not included since they are usually
present on the parent (Contact/Customer/User) struct. This avoids data duplication, but more importantly, 
it allows the package to avoid tackling name handling. Storing a name requires up to 5 fields 
(title, given_name, additional_name, family_name, suffix), and choosing the tradeoffs in this area 
is the job for another package.

## Countries

The next step is to add a country list, giving us available country codes and country names.
There are two such lists available, one from CLDR and one from ISO. You'd think we'd want the ISO
one, but you'd be mistaken. Most software uses CLDR data because it matches colloquial usage more closely (e.g. "Russia" instead of "Russian Federation"). 

CLDR provides its list in [JSON format](https://raw.githubusercontent.com/unicode-cldr/cldr-localenames-full/master/main/en/territories.json), allowing us to fetch it and generate a countries.go
file via *go generate*. We're now always one command away from latest data.

To reduce data size, this package only includes country names in English. 
Translated country names can be fetched on the frontend via [Intl.DisplayNames](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DisplayNames). 
Alternatively, one can plug in [x/text/language/display](https://pkg.go.dev/golang.org/x/text/language/display) by setting a custom CountryMapper on the formatter. 

## Address formats

We're still missing country-specific rules that would allow us to validate and format an address.
We'll fetch those from Google's [Address Data Service](https://chromium-i18n.appspot.com/ssl-address), generating an AddressFormat struct for each country code.

An address format provides the [following information](https://github.com/bojanz/address/blob/master/formats.go#L6):

- Which fields are used, and in which order.
- Which fields are required.
- Labels for the sublocality, locality, region and postal code fields.
- Regular expression pattern for validating postal codes.
- Regions, with local names where relevant (e.g: Okinawa / 沖縄県).

[Helpers](https://github.com/bojanz/address/blob/master/address.go#L61) are then provided for validating required fields, regions and postal codes.

It is tempting to expand gen.go to always generate formats.go from Google, forbidding contributors from modifying the
included data and directing them to open bug reports [upstream](https://github.com/google/libaddressinput/issues).
This is the approach commerceguys/addressing took, and over the years over 20 bug reports were accepted and corrected.
However, bug reports sometimes took years to resolve, frustrating contributors and requiring forks and local overrides.

This time around, the package owns its dataset. The community is free to send PRs against formats.go, evolving the
data in a direction of its choosing. We've already applied a number of fixes against Google's data, applying recent
ISO updates (e.g. China's new ISO codes). Of course, we'll continue to contribute bug reports against upstream, and 
periodically apply their updates where possible.

To minimize the size of the dataset, we don't include predefined localities or sublocalities, which Google defines
for certain countries (Brazil, Chile, China, Hong Kong, Japan, South Korea, Taiwan). This brings the size of formats.go 
down from over a megabyte to \~80kb.

## Widget

Implementing an address widget requires us to write JavaScript. When the country changes, we need to re-render
the other fields based on address format data. But where do we get this data? Do we duplicate it in JS, and 
risk having the backend and the frontend potentially use different data? The more common approach is to fetch it from 
the backend, maintaining a single source of truth. When the dataset is large, a single GET request can only cary
a single country's address format, and a new request must be made each time the country changes. This is how
most widgets relying on Google's address data work, and it's something I wanted to change.

The package provides a [handler](https://github.com/bojanz/address/blob/master/http.go#L12) which can be used with any router:
```go
r.Get("/address-formats", address.FormatHandler)
```
It filters data by the provided locale (query string or header) to reduce the response size by another 20%.
For example, if the locale is "fr", there is no need to return non-Latin region names. The result?
A response size of \~45kb, or **\~14kb** if gzip compression is used.

And that right there is this package's entire raison d'etre. Making the entire dataset small enough
to fit into a singe GET request, making every country change instantaneous.

## Formatter

Let's end this post with a bit more of code. The address.Formatter displays
an address as HTML, using the country's address format.

The country name can be omitted, for the use case where all addresses belong to the same country. 

```go
addr := address.Address{
    Line1:       "1098 Alta Ave",
    Locality:    "Mountain View",
    Region:      "CA",
    PostalCode:  "94043",
    CountryCode: "US",
}
locale := address.NewLocale("en")
formatter := address.NewFormatter(locale)
output := formatter.Format(addr)
// Output:
// <p class="address" translate="no">
// <span class="line1">1098 Alta Ave</span><br>
// <span class="locality">Mountain View</span>, <span class="region">CA</span> <span class="postal-code">94043</span><br>
// <span class="country" data-value="US">United States</span>
// </p>

addr = address.Address{
    Line1:       "幸福中路",
    Sublocality: "新城区",
    Locality:    "西安市",
    Region:      "SN",
    PostalCode:  "710043",
    CountryCode: "CN",
}
locale := address.NewLocale("zh")
formatter := address.NewFormatter(locale)
formatter.NoCountry = true
formatter.WrapperElement = "div"
formatter.WrapperClass = "postal-address"
output := formatter.Format(addr)
// Output:
// <div class="postal-address" translate="no">
// <span class="postal-code">710043</span><br>
// <span class="region">陕西省</span><span class="locality">西安市</span><span class="sublocality">新城区</span><br>
// <span class="line1">幸福中路</span>
// </div>
```

## Conclusion

Addressing is a complex topic, but the resulting implementation doesn't need to be.
In \~1500 lines of code, and \~85kb of data we tackle many problems, creating a foundation
that can be built upon. I am excited to see how the community makes use of it.


