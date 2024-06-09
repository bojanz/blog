---
author: "Bojan Zivanovic"
date: 2020-11-06
title: "Go constants and JSON: To iota and back"
slug: "go-constants-json-iota"
---

Let's talk constants! Today's use case is [bojanz/address](https://github.com/bojanz/address).

Certain field labels vary from country to country. A PostalCode field
is usually labelled "Postal code", but in the US it is a "ZIP code".
A Region field might be labelled "State" or "Province", among other options.

We store country-specific addressing rules in an address.Format struct, which tells us the labels to use.
Here's a simplified example:
```go
type Format struct {
  Layout            string          `json:"layout,omitempty"`
  SublocalityType   SublocalityType `json:"sublocality_type,omitempty"`
  LocalityType      LocalityType    `json:"locality_type,omitempty"`
  RegionType        RegionType      `json:"region_type,omitempty"`
  PostalCodeType    PostalCodeType  `json:"postal_code_type,omitempty"`
}
```

We want to predefine possible values, communicating to callers which labels they'll
need to prepare (and possibly translate). We also want these values to take as little memory
as possible, since there will be around 200 address formats.
This is a classic enum use case, implemented in Go via sets of constants.

I usually define constants at the top of the file which uses them, but since there's
around 30 possible constants here, I will create a [const.go](https://github.com/bojanz/address/blob/master/const.go) file and define them there.
Here are 2 of the 4 types defined:
```go
type LocalityType uint8

const (
	LocalityTypeCity LocalityType = iota
	LocalityTypeDistrict
	LocalityTypePostTown
	LocalityTypeSuburb
)

type PostalCodeType uint8

const (
	PostalCodeTypePostal PostalCodeType = iota
	PostalCodeTypeEir
	PostalCodeTypePin
	PostalCodeTypeZip
)
```

Each constant name is prefixed with the type it belongs to. This groups possible
values together in autocomplete dropdowns and documentation, and prevents
name collisions (e.g. we have both a SublocalityTypeSuburb and a LocalityTypeSuburb).

We use a uint8 for minimal memory usage, each value is only 1 byte. The iota
keyword allows us to assign a numeric value to each constant, starting from 0, without having
to type out the numbers ourselves. All this has another great benefit: the zero value is
useful, allowing us to leave out default values:
```go
var formats = map[string]Format{
	Layout: "%1\n%2\n%3\n%P %L",
	// We can delete the next lines, they match default/zero values.
	LocalityType: LocalityTypeCity,
	PostalCodeType: PostalCodeTypePostal,
}
```

And thanks to "omitempty" in the JSON struct tags, when marshaling the formats
to JSON (e.g. to power a frontend widget), all zero values will be left out, reducing the size of the payload.

There's only one problem remaining. Since the types are uint8 under the hood,
that's how they'll be converted to JSON. A "postal_code_type" will be "3" instead
of "zip". This makes it harder for the frontend to understand the data, and it makes the values
positional, where a new value added before the end would reindex all following values, breaking
client code.

The easiest way to fix this is to define MarshalText and UnmarshalText
methods for our types, converting the values to/from strings when marshalled
to JSON, XML, and other formats.

We start by defining a fixed-size array which holds a name for each numeric value:

```go
type LocalityType uint8

const (
	LocalityTypeCity LocalityType = iota
	LocalityTypeDistrict
	LocalityTypePostTown
	LocalityTypeSuburb
)

var localityTypeNames = [...]string{"city", "district", "post_town", "suburb"}
```

An array saves us a bit of memory compared to a slice. Note the "[...]" trick to avoid specifying a count. 
Now let's use it:
```go
func (l LocalityType) String() string {
	if int(l) >= len(localityTypeNames) {
		return ""
	}
	return localityTypeNames[l]
}

// MarshalText implements the encoding.TextMarshaler interface.
func (l LocalityType) MarshalText() ([]byte, error) {
	return []byte(l.String()), nil
}

// UnmarshalText implements the encoding.TextUnmarshaler interface.
func (l *LocalityType) UnmarshalText(b []byte) error {
	aux := string(b)
	for i, name := range localityTypeNames {
		if name == aux {
			*l = LocalityType(i)
			return nil
		}
	}
	return fmt.Errorf("invalid locality type %q", aux)
}
```

At this point some of you might be thinking "I could have used [Stringer](https://godoc.org/golang.org/x/tools/cmd/stringer)
to generate these names for me". But that wouldn't solve the problem, since Stringer (as its name says) only generates String()
methods, leaving MarshalText() and UnmarshalText() unimplemented.

And there we have it, fast and flexible JSON-ready constants. For bonus points, take a look at
[const_test.go](https://github.com/bojanz/address/blob/master/const_test.go) in the package for matching tests.
