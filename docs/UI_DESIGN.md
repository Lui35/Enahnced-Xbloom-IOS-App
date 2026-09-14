# Original studio design, polished

Recipe cards use the actual main-branch layout as their baseline: the asymmetric HOT/ICED tile, pour count and pattern, AI badge beside the name, original stats order, and chevron. Other library and editor screens retain their original structure. Home is intentionally redesigned to balance machine controls and recent coffee.

## Theme

Use neutral slate surfaces with warm amber actions and cream coffee accents. Surfaces are lighter than the original near-black green theme. Green continues to mean connected or complete; coral and blue distinguish hot and iced coffee; purple identifies feedback enhancement.

Decorative background glows, header gradients, and the Home machine-card ornament are removed. Identity panels use solid accent fills. Gradients remain where they communicate activity or data, including recipe generation and pour charts.

## Retained improvements

- Recipe rows retain the main-branch format, adding a scaled common height, hot/iced edge markers, and clearer source text. All, Favorites, Hot, and Iced share one segmented filter; there is no separate Favorites toggle.
- Home has one machine connection card, manual controls, a recipe chooser, and the last recorded brew. Favorites and library shortcuts follow; brew changes can be expanded, and sync status appears separately without a duplicate machine connection card.
- The original bean cards retain their details and actions, with a simpler bag-inventory bar and explicit “Design with AI” wording.
- Generation keeps the original orbit, shimmer, and travelling border. Reduce Motion pauses continuous movement; cancel and leave actions remain accessible.
- Shared primary actions indicate disabled state. Stepper buttons have larger hit areas, and dial borders are quieter at rest.
- The replacement app icon remains in the asset catalog; see APP_ICON.md.

## Verification

Data models, backend generation, Bluetooth commands, and persistence code are unchanged by this polish. Build and simulator checks cover the restored layouts. Physical brewing still requires device verification.

The simulator build and all 20 existing app tests passed after restoring the original screens. Visually checked the original Home dashboard and bean cards with the new palette. `git diff --check` passed.

Verified All/Hot/Iced/Favorites filtering in the simulator, including the Favorites empty state. The Home recipe chooser navigates to the recipe library.
