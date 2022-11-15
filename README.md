# twitling : Twitter link digest

## Problem: I can't keep up with the Internet

I often check Twitter on my phone. When I see tweets with links in them I tend to skip over them intending to return later when I'm on a computer with a full-size screen, and then forget about them either because I find something else to look at or I can't be bothered with scrolling all the way down again. And looking through old tweets is nearly as bad on the full-size twitter web site as it is in a mobile client.

## Proposed solution: I need a computer program to read the Internet for me

Thus, Twitling: a small script consisting of Ruby and Sinatra and OmniAuth and the Twitter gem and Typhoeus to grab links in parallel, the function of which is to read one's timeline and display the resolved URL, the title and an excerpt from the text of each link that was posted. 
