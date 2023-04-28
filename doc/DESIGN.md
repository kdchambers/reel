Reel Design Document
======

This document is intended to showcase the current design status of the project via the figma UI mockup and workflows. 

Only the principal workflows are included, but if you feel like a use-case isn't being covered either here or in the figma file, please file an issue with the *design* issue label attached.

The following Figma file contains the mockups of the application and should be used in conjunction with this file to understand each workflow.

[Reel Figma Design Doc](https://www.figma.com/file/zYHC4GER4ew08WQE67Bfix/Reel?node-id=0%3A1&t=IMQdfPE67a4a7zUS-1)

TODO: 

- [ ] Create "Add Source" popup dialog mockup
- [ ] Create "Add Transition" popup dialog mockup
- [ ] Add workflows for taking screenshots
- [ ] Add workflows for streaming

## Workflows

### **1.** Setup a recording with 2 scenes

1. Click the **Add** icon under **Sources**
2. Select a Desktop Screencapture source and apply desired settings
3. Click **Add**
4. Repeat for other sources that you wish to add (Microphone, Desktop audio loopback, etc)
5. Click the **Add** icon next to the **Scene Selector**.
6. Type in the name of the Scene
7. Add desired sources as specified above
8. Click on the **Record** tab
9. Specify desired settings for the recording
10. Click the **Record** button


### **2.** Transition between scenes using keyboard shortcut

**NOTE:** Global hotkeys are implemented at the compositor level. If your compositor supports them, you will need to set the same shortcut there. Otherwise this will only work when Reel is in focus

1. Add 2 Scenes as shown above
2. Use the **Scene Selector** to select scene #1
3. Click the **Add** button under **Transitions**
4. Specify desired properties and set **Destination Scene** to scene #2
5. Click the **Keyboard Shortcut** button
6. Press the desired key shortcut (E.g Ctrl + t)
7. Click the **Apply** button
8. Select Scene #2
9. Add a transition to this scene in the same manner, setting **Destination Scene** to be scene #1
10. Press the desired key shortcut (E.g Ctrl + p)
11. Select the scene that you want to start the recording with using the **Scene Selector**
12. Select **Record** tab
13. Click the **Record** button
14. Use set shortcut keys to switch between scenes
