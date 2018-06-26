---
author: "Bojan Zivanovic"
date: 2014-04-25
title: Storing hierarchical data - Materialized Path
slug: "storing-hierarchical-data-materialized-path"
---

Web applications often need a way to represent and store hierarchies.  
A menu with its submenus. A category with its subcategories. A comment and its replies.
Storing the hierarchy, and later reconstructing it from the stored data is just a part of the puzzle. We also need a way to find the parents or children of an item. We need to be able to re-parent an item (move it to another part of the hierarchy). Finally, there is the need to order items in a way that reflects their position in the hierarchy.

There are several ways to do this, each with its own pros and cons:

- Adjacency list
- Nested set
- Closure table (aka bridge table)
- Materialized path (path enumeration)

I won’t compare all of them, but a quick surf through [search results](http://www.slideshare.net/billkarwin/models-for-hierarchical-data) and [StackOverflow](http://stackoverflow.com/questions/4048151/what-are-the-options-for-storing-hierarchical-data-in-a-relational-database) will tell you that closure table and materialized path are potentially the two best choices.

Looking at our storage requirements, materialized path starts to look like a simpler option:   
Storing the hierarchy in a materialized path requires only one column in the table.  
Storing the hierarchy in a closure table requires an additional table with a large number of rows.  
The closure table also won’t work if you need to sort items by hierarchy, and re-parenting items is slow and costly. On the other hand, it’s normalized, which can’t be said for materialized paths.

So, let’s give materialized paths a shot. We’ll then see how our encoding trick makes it even better.

### The basic idea
Let’s say we’re an ecommerce store. Each product is a part of the product catalog, represented as a hierarchy. For example:  
*Electronics & Computers -> Games -> Xbox360*

A materialized path visualizes the entire hierarchy in a single varchar column:
```
ID | NAME                     | PATH
100 | Electronics & Computers | /100
101 | Games                   | /100/101
102 | Xbox360                 | /100/101/102
103 | PS4                     | /100/101/103
```
We use LIKE to browse the hierarchy, REPLACE to modify it:

```
-- Find children of "Games":
SELECT * FROM catalog WHERE path LIKE “/100/101/%”
-- Reparent an item:
UPDATE catalog SET path = REPLACE(path, ‘/100/101’, ‘/200/201’)
  WHERE path LIKE ‘/100/101/%’
```

What about performance? Here’s what [django-threebeard](https://tabo.pe/projects/django-treebeard/docs/tip/mp_tree.html) has to say:

> If you think that LIKE is too slow, you’re right, but in this case the path field is indexed in the database, and all LIKE clauses that don’t start with a %character will use the index.

Now let’s look at some problems.

– How do I sort the items by hierarchy?

Remember that path is a varchar field. This means that if you ORDER BY path ASC you will see “11/2” coming before “5/10”. Sometimes this might not be what you expect.

– What if my hierarchy can’t fit inside 255 characters (usual varchar length)?

Ids can be large, which can reduce the size of the hierarchy significantly.

We fix both problems with the same trick: we encode the ids and eliminate the separators (“/” in our case).

### The encoding

We start by converting the ids to [base36](https://en.wikipedia.org/wiki/Base_36):
```
print base_convert("1000", 10, 36); // RS
print base_convert("10 000", 10, 36); // 7PS
print base_convert("100 000", 10, 36); // 255S
print base_convert("1 000 000", 10, 36); // LFLS
```

As you can see, our ids shrink significantly.  
This is the same trick that Reddit uses for its comment & post ids.

Now we get rid of the separators. There are two ways to do it:

1) Enforce fixed-width ids

This is what django-treebeard does. Each id is 4 characters long. Shorter ids are padded (“1” becomes “0001”).
That gives you 1 679 615 as the biggest possible id:

```
print base_convert('ZZZZ', 36, 10); // 1 679 615
```
The predictable id length makes it simple to handle and parse. But it’s wasteful because of the padding, many ids might only need one or two characters.

Using this strategy, “/100/101/102” becomes “002T002U002V”. Note the six zeros that are extra padding. Since each segment is 4 characters long, your maximum hierarchy depth is 63 levels.

Of course, you can always increase the padding at the expense of maximum depth:
A 5 character segment will give you 60 466 175 as the highest id, but your maximum depth is now 50 levels (which is still good). Tweak until happy.

2) Store a length prefix

This is the trick that Drupal has been using for a long time for its comments (called “vancode” up until Drupal 8).
The first number tells you the length of the id that comes after it.
So if your id is “2T”, that is 2 characters long, so you store “22T”. Note that the first “2” is also base36 encoded, allowing the id to have up to 35 digits.

Using this strategy, “/100/101/102” becomes “22T22U22V”. Three characters saved, allowing for a potentially higher hierarchy depth, at the cost of a slightly more complex parsing function (read length, read $length number of characters, read new length…).

Both of these end results, “002T002U002V” and “22T22U22V” sort correctly.

### Understanding collations for fun and profit

Remember that we used base36 to encode the paths, where each number is represented by a combination of 36 characters (numerals 0–9 and letters A–Z).
Note that only upper-case letters are used, making this number system case-insensitive. Since it’s case-insensitive, it will sort properly on all databases.

The sorting and comparison behavior of a column is determined by its collation.
PostgreSQL and SQLite use case-sensitive collations by default, but MySQL uses a case-insensitive collation by default, which means “A” and “a” are the same to it, so we can’t use them to represent different numbers.
But if we specify a different collation for the path column, we can add lower-case letters into the mix (giving us Base62) or use even more characters from the [ASCII table](http://asciiset.com/), allowing us to store bigger numbers as our ids.

The collation we want to use in MySQL is *latin1_bin*. It sorts all characters using their binary values, matching the default SQLite and PostgreSQL (“C collation”) behavior.

To convert a number from base10 to an arbitrary base we need [numconv](https://tabo.pe/projects/numconv) in Python or a [bcmath-based function](http://www.php.net/manual/en/ref.bc.php#25336) in PHP.

ASCII has 95 printable characters (including the space character), which allows us to construct a “base95” with the following “alphabet”:

```
!"#$%&'()*+,-./0123456789:;?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~
```
If we’re using fixed-width 4-character ids, the biggest id we can represent is 81 450 624. If we’re using 5-character ids, our biggest id is 7 737 809 374.

Generally we don’t care about reading the path, it’s supposed to be handled by our code, so we can use a “base128” that uses every single ASCII character, printable and non-printable. This gives us 268 435 455 as the biggest id we can represent in 4 characters, or 34 359 738 367 for 5 characters.

As you can see, both base95 and base128 can represent numbers higher than a 32bit integer in 5 characters.

chx’s original idea was to use base256 (the entire extended-ASCII table, better known as “latin1”), and the collations should support that. However, I couldn’t get django-treebeard tests to pass with that alphabet. It might be due to my poor Python skills, but it needs investigation before usage.

### Drupal
[Entity Tree](http://drupal.org/project/entity_tree) is chx’s first attempt to optimize the materialized path. The length prefix + base256 approach described here is his preferred solution to the problem nowadays.

[Tree](http://drupal.org/project/tree) provides a nice API for hierarchical data, as well as pluggable storage. Right now it only supports adjacency lists and nested sets. A plugin for materialized paths could be written. Followed by a Drupal 8 port of course 🙂

### Further reading
The books [SQL Design Patterns](http://www.rampant-books.com/book_0601_sql_coding_styles.htm) and [Trees and Hierarchies in SQL for Smarties](http://www.amazon.com/Hierarchies-Smarties-Edition-Kaufmann-Management/dp/0123877334) examine the various approaches to storing hierarchical data.

### Credits
Co-written by Karoly Negyesi (chx) and Bojan Zivanovic (bojanz).  
Special thanks to Damien Tournoud and Gustavo Picón.
