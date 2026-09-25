{smcl}
{* *! version 0.2.3  24sep2026}{...}
{vieweralsosee "[D] merge" "help merge"}{...}
{vieweralsosee "[D] frames" "help frames"}{...}
{viewerjumpto "Syntax" "hmerge##syntax"}{...}
{viewerjumpto "Description" "hmerge##description"}{...}
{viewerjumpto "Options" "hmerge##options"}{...}
{viewerjumpto "Differences from merge" "hmerge##differences"}{...}
{viewerjumpto "Remarks" "hmerge##remarks"}{...}
{viewerjumpto "Examples" "hmerge##examples"}{...}
{viewerjumpto "Stored results" "hmerge##results"}{...}
{viewerjumpto "Author" "hmerge##author"}{...}
{title:Title}

{phang}
{bf:hmerge} {hline 2} Merge m:1 and 1:1 without sorting the master data (prototype)


{marker syntax}{...}
{title:Syntax}

{p 8 16 2}
{cmd:hmerge} {cmd:m:1} {varlist} {cmd:using} {it:{help filename}} [{cmd:,} {it:options}]

{p 8 16 2}
{cmd:hmerge} {cmd:1:1} {varlist} {cmd:using} {it:{help filename}} [{cmd:,} {it:options}]

{synoptset 22 tabbed}{...}
{synopthdr}
{synoptline}
{synopt:{opt keepus:ing(varlist)}}variables to keep from using data; default is all{p_end}
{synopt:{opth gen:erate(newvar)}}name of new variable to mark merge results; default is {cmd:_merge}{p_end}
{synopt:{opt nogen:erate}}do not create {cmd:_merge} variable{p_end}
{synopt:{opt nol:abels}}do not copy value-label definitions from using{p_end}
{synopt:{opt keep(results)}}which match results to keep{p_end}
{synopt:{opt assert(results)}}specify required match results{p_end}
{synopt:{opt norep:ort}}do not display match result summary table{p_end}
{synopt:{opt sort}}sort the result by {varlist}{p_end}
{synopt:{opt sorted}}accepted for compatibility with {cmd:merge}; has no effect{p_end}
{synoptline}
{p 4 6 2}
Options {opt update}, {opt replace}, {opt force}, and the merge types {cmd:1:m}, {cmd:m:m},
and {cmd:1:1 _n} are passed to {helpb merge} unchanged; see
{help hmerge##differences:Differences from merge}.


{marker description}{...}
{title:Description}

{pstd}
{cmd:hmerge} joins the dataset in memory (master) with a Stata dataset on disk (using)
on key variables, with the same syntax and results as {helpb merge} for many-to-one and
one-to-one merges. It differs in how it matches. {cmd:merge} sorts the master data by
the key variables and then joins the two sorted datasets. {cmd:hmerge} reads the using
data into a temporary frame, builds a lookup table on the using keys (see
{help hmerge##remarks:Remarks}), and looks up each master observation where it already
is. The master data are never sorted.

{pstd}
Skipping the sort makes {cmd:hmerge} several times faster than {cmd:merge} on large,
unsorted master data when the result does not need to be sorted by the key variables
(for example, 7.8 times faster for 10 million master observations, one integer key,
and 100,000 using observations in the author's benchmarks on Stata/MP 17). If the
result will be sorted by the key variables anyway, {cmd:merge} is as fast or faster.

{pstd}
{cmd:hmerge} is a prototype. It is implemented as an ado-file and a C plugin (Stata
plugin interface 3.0) and requires Stata 17 or later; it has been tested only with
Stata/MP 17. A compiled plugin is currently provided for macOS on Apple silicon only.
On other platforms {cmd:hmerge} displays a note and runs {cmd:merge} instead.


{marker options}{...}
{title:Options}

{phang}
{opt keepusing(varlist)}, {opt generate(newvar)}, {opt nogenerate}, {opt nolabels},
{opt keep(results)}, {opt assert(results)}, and {opt noreport} work as in
{helpb merge}. {it:results} are {cmd:master} (or 1), {cmd:using} (2), and {cmd:match}
(3), with the abbreviations {cmd:merge} accepts.

{phang}
{opt sort} sorts the result by {varlist} after merging. It gives back most of the speed
advantage, and with a large using dataset or a 1:1 merge {cmd:merge} is faster.

{phang}
{opt sorted} is accepted so that {cmd:merge} commands can be changed to {cmd:hmerge}
without editing their options. It has no effect, because {cmd:hmerge} does not sort
either dataset, and {cmd:hmerge} does not check whether the data are sorted.


{marker differences}{...}
{title:Differences from merge}

{phang}
1. {it:Order of master observations.} {cmd:hmerge} keeps master observations in their
original order. After {cmd:merge m:1}, master observations are in key order (and the
sort order is cleared); after {cmd:merge 1:1} with no using-only observations, the data
are sorted by the key variables. Using-only observations are appended at the end, in
key order, by both commands. If it appends any, {cmd:hmerge} clears the dataset's sort
order. Specify {opt sort} to obtain key order throughout; see also
{help hmerge##remarks:Remarks}.

{phang}
2. {it:Notes and characteristics} of using variables are not copied.

{phang}
3. {cmd:r()} holds {cmd:r(path)} (see {help hmerge##results:Stored results}) rather than
the results of {cmd:merge}'s internal {cmd:count}.

{phang}
4. {it:Fallbacks.} These are handled by calling {cmd:merge}, with a note: {cmd:1:m},
{cmd:m:m}, and {cmd:1:1 _n} merges; options {opt update}, {opt replace}, and
{opt force}; strL key or payload variables; a using file on the web; master and using
data whose observations together could reach 2,147,483,647, the largest observation
count the plugin interface can address; and platforms without a compiled plugin.

{pstd}
In every other respect the result should be identical to {cmd:merge}: values,
{cmd:_merge}, variable order, storage types (including {cmd:merge}'s promotion of master
variables), formats, variable labels, value labels, error messages and codes, and the
data left in memory after an error. Please report any difference.


{marker remarks}{...}
{title:Remarks}

{pstd}
{it:Code that relies on merge's key order.} Because master observations stay in their
original order, code that compares adjacent observations right after a merge, without
{cmd:by} or {cmd:sort}, gives different results after {cmd:hmerge}. For example,

{phang2}{cmd:. generate byte first = id != id[_n-1]}{p_end}

{pstd}
flags the first observation of each {cmd:id} only if the data are in {cmd:id} order.
After {cmd:merge m:1} they are, even though the sort order is cleared; after
{cmd:hmerge} they are not. Write {cmd:bysort id: generate byte first = _n == 1}, which
is correct after either command, or specify {opt sort}.

{pstd}
{it:Matching.} Keys are compared exactly, byte for byte, so missing values ({cmd:.},
{cmd:.a}, ..., {cmd:.z}) and empty strings are keys like any other, as in {cmd:merge}. When
there is a single numeric key and the using values are integers over a compact range,
the lookup table is a direct lookup table: an array indexed by key value minus the
smallest key. Otherwise it is a hash table with open addressing. In a hash table a match
is always confirmed by comparing the full key values, so hash collisions cannot produce
wrong matches.

{pstd}
{it:Plugin memory.} The plugin keeps the using keys and variables in memory between two
plugin calls. This works in current Stata but is not documented behavior of the Stata
plugin interface; {cmd:hmerge} checks a token on every call and stops with an error
rather than use stale data. With a small using dataset {cmd:hmerge} needs less memory
than {cmd:merge}; with a very large one it can need more.


{marker examples}{...}
{title:Examples}

{pstd}One-to-one (example from {manlink D merge}){p_end}
{phang2}{cmd:. webuse autosize, clear}{p_end}
{phang2}{cmd:. tempfile size}{p_end}
{phang2}{cmd:. save `size'}{p_end}
{phang2}{cmd:. webuse autoexpense, clear}{p_end}
{phang2}{cmd:. hmerge 1:1 make using `size'}{p_end}

{pstd}Many-to-one (example from {manlink D merge}){p_end}
{phang2}{cmd:. webuse dollars, clear}{p_end}
{phang2}{cmd:. tempfile dollars}{p_end}
{phang2}{cmd:. save `dollars'}{p_end}
{phang2}{cmd:. webuse sforce, clear}{p_end}
{phang2}{cmd:. hmerge m:1 region using `dollars'}{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:hmerge} stores the following in {cmd:r()}:

{synoptset 15 tabbed}{...}
{p2col 5 15 19 2: Macros}{p_end}
{synopt:{cmd:r(path)}}{cmd:direct} or {cmd:hash} when the plugin joined the data (the
kind of lookup table used), or {cmd:native:} followed by the reason when the job was
handed to {cmd:merge}{p_end}
{p2colreset}{...}


{marker author}{...}
{title:Author}

{pstd}
CJ Libassi{break}
Source, tests, and benchmarks: {browse "https://github.com/clibassi/hmerge"}

{pstd}
The direct lookup table for integer keys follows the approach used in {cmd:gtools}
by Mauricio Cáceres Bravo. {cmd:hmerge} was written with a lot of help from an AI coding
assistant (Anthropic's Claude); its test suite compares results against {cmd:merge}.
