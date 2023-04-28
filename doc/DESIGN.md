Reel Design Document
======

This document is intended to showcase the current design status of the project via the figma UI mockup and workflows. 

Only the principal workflows are included, but if you feel like a use-case isn't being covered either here or in the figma file, please file an issue with the *design* issue label attached.

[Reel Figma Design Doc](https://www.figma.com/file/zYHC4GER4ew08WQE67Bfix/Reel?node-id=0%3A1&t=IMQdfPE67a4a7zUS-1)

![background](https://user-images.githubusercontent.com/14359115/235041741-7221924b-9b85-4c1d-a19c-7109e78d0064.svg)

## Workflows

### **1.** Setup a recording with 2 scenes

1. Click the **Add** icon under **Sources** \
    *Source type selector appears*
2. Select "Video" \
    *Pipewire desktop selector appears*
3. Select Window or Desktop source to add \
    *Pipewire desktop selector closes*
4. Apply desired settings to source
5. Click **Add** \
    *Add sources dialog closes* \
    *The source is listed in **Sources** sections with provided label*
6. Repeat for other sources that you wish to add (Microphone, Desktop audio loopback, etc)
7. Click the **Add** icon next to the **Scene Selector** \
    *Create scene dialog opens*
8. Type in the name of the Scene and click **Add** \
    *Create scene dialog closes* \
    *Scene Selector displays name of Scene*
9. Add desired sources as specified above
10. Click on the **Record** tab
11. Specify desired settings for the recording
12. Click the **Record** button \
    *Video recording begins*
    *Record button text changes to Stop*


### **2.** Transition between scenes using keyboard shortcut

**NOTE:** Global hotkeys are implemented at the compositor level. If your compositor supports them, you will need to set the same shortcut there. Otherwise this will only work when Reel is in focus

1. Add 2 Scenes as shown above
2. Use the **Scene Selector** to select scene #1
3. Click the **Add** button under **Transitions** \
    *Add transition dialog appears*
4. Specify desired properties and set **Destination Scene** to scene #2
5. Click the **Keyboard Shortcut** button \
    *Pending keypress dialog appears*
6. Press the desired key shortcut (E.g Ctrl + t) \
    *Pending keypress dialog closes* \
    *Keyboard shortcut button shows **Ctrl + t***
7. Click the **Apply** button \
    *Add transition dialog closes*
8. Select Scene #2
9. Add a transition to this scene in the same manner, setting **Destination Scene** to be scene #1
10. Press the desired key shortcut (E.g Ctrl + p)
11. Select the scene that you want to start the recording with using the **Scene Selector**
12. Select **Record** tab
13. Click the **Record** button \
    *Video recording begins*
14. Use set shortcut keys to switch between scenes

### **3.** Save and load a Scene Collection

1. Setup 1 or more scenes
2. Click the **File** icon from the icons bar \
    *File Dialog appears*
3. Click **Export Scene Collection** button \
    *XDG file chooser popup appears*
4. Use File Chooser popup to select output file location \
    *XDG file chooser popup closes*
    *UI indicates when file have been saved successfully*
5. Close Reel
6. Open Reel
    *Reel opens to an empty scene collection*
7. Click the **File** icon from the icons bar \
    *File Dialog appears*
8. Click **Import Scene Collection** button \
    *XDG file chooser popup appears*
9. Select previously saved scene collection file \
    *XDG file chooser popup closes* \
    *All scenes from previous session are loaded* 

### **4.** Play introduction video at beginning of recording

1. Setup a scene
2. Click **Add** button for Overlays \
    *Add overlay popup appears*
3. Select **Video Source** \
    *XDG file chooser opens*
4. Navigate and select video file to use as intro \
    *XDG file chooser closes*
5. Select *Play on start* checkbox
6. Click **Add** button \
    *Add overlay popup closes* \
    *Overlay is listed in sidebar*
7. Start recording with scene that has the overlay that was created \
    *Video starts recording* \
    *Video intro starts playing* \
    *When video intro is finished, the overlay is deactivated and the scene is visible as normal*

## Misc Questions

- Q: How to position, scale, etc visual sources? \
A: Same as OBS, either click on the source in the preview, or in the sources side panel and move / scale it.


TODO: 

- [ ] Add mockup for adding a non-pipewire source \
    In this case Reel will have to list all available sources
- [ ] Add workflows for taking screenshots
- [ ] Add workflows for streaming
