     src: 'a' -> dst: 'b' *
     src: 'a' -> dst: 'c' *
  starting 4 threads for background file closing (?)
   b: remote moved from a -> m (premerge)
   c: remote moved from a -> m (premerge)
- first verify copy metadata was kept
  rebasing 2:add3f11052fa "other" (tip)
- next verify copy metadata is lost when disabled
  rebasing 2:add3f11052fa "other" (tip)
Verify we duplicate existing copies, instead of detecting them
  rebasing 3:47e1a9e6273b "copy a->b (2)" (tip)