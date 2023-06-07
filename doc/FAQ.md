# FAQ

## Why Wayland? Will other systems be supported later on?

Most likely yes, but not until Reel is more stable and feature complete. The reasoning for this is that I want to provide the best experience possible for those whom Reel is being offered to, and not take on additional mantainance work while the core design is still in-flux. The user interface is already implemented as an optional part of the system, so adding Windows, MacOS, etc windowing and screencasting support shouldn't cause significant incompatibilties later on.

## Performance Metrics?

Setting up automated performance metrics is a TODO, but anecdotally Reel generally has a ~35% memory consumption compared to OBS.

|Activity | Reel | OBS |
| ---- | ----- | ----- |
| Idle | 80MB | 220MB|
| *Recording | 160MB | 500MB |

\* Recording with 2 video sources (Screencast & webcam) as well as audio input.

CPU utilization is a little tricker to give a useful estimate for, but performance that isn't on-par or better than OBS will always be considered a bug.

## Who should consider Reel?

The first users who might benefit from this project are Wayland users who want to be able to take advantage of compositor specific screencast extensions. For example, if you're using a Wlroots based compositor (Such as sway), Reel doesn't require any additional dependencies (Such as Pipewire) for screencasting.

Additionally, those who are looking for a slightly less resource heavy alternative to OBS and have simple recording requirements might find Reel adecuate early in it's development.

## Licence

Reel is provided under the MIT license. Although generally open source *applications* (not libraries) tend to favor GPL to avoid companies exploiting free labor and potentially using your work to produce anti-consumer products, I've decided against that for Reel for the following reason.

My development approach with Reel is to write bespoke components that reduce certain types of complexity and allow for more optimal machine code generation. That means, I write code for Reel and Reel alone. I'm not trying to create generic, reusable components to be depended on by various projects. If I'm working on a separate project that requires some code that I've already written, I will copy, paste and adjust it for my specific needs. Seeing as I wrote this code in the first place, that's easy to do. Hey, I might even see something I'd like to improve.

So, although I don't plan on releasing a library version of, say, the GUI system, I think Reel will stand as a good reference for people who are interested in taking a similar development path and want a non-convoluted, straight to the point codebase to see how things work under the hood. As such, I wish to maintain the property that other developers can copy and paste any part of the source code into their own project without having to sit and think about the implications of GPL in their projects. To me this is another aspect of producting truly "optimal" software that serves the community.

I think the chances of the source code ever being misused are *very* low, and not worth the anti-consumer restriction that would be placed on other developers who might go on to make positive contributions to software.

## Funding

The intended funding model is donations, Reel will always be free (Both beer and freedom) and pro-consumer software. I hope that one day I can make a modest living from my contributions along with any paid freelance work I can find.

## Is there a development roadmap?

No. It's still quite early to release a useful roadmap but check-in later on!