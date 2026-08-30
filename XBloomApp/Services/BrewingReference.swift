import Foundation

/// The brewing-science corpus the recipe prompts reason from.
///
/// Sent verbatim on every `generateRecipe`/`enhanceRecipe` call and placed at
/// the head of the prompt so the static half stays cacheable upstream. Where
/// the published literature disagrees with what this machine can actually do —
/// the grind dial, the ratio bands, agitation as two booleans — the machine
/// wins, and the conflicting numbers were rewritten rather than left to be
/// resolved by the model at generation time.
enum BrewingReference {
    static let text = """
    # Brewing reference

    This is the body of practice to reason from. It is not a menu of recipes to
    copy. Machine limits stated in the task instructions always override any
    number here.

    ## 0. What this machine can and cannot do

    - It pours: volume, temperature, flow rate (3.0-3.5 ml/s), pattern (center,
      circular, spiral), and a pause after each pour.
    - Its only agitation controls are `agitationBefore` and `agitationAfter` on
      each pour. There is no stirring, no swirling by hand, no Melodrip, no
      pouring from height, no immersion switch.
    - Translate a technique into what the machine has. "Swirl after the bloom"
      becomes `agitationAfter` on the bloom pour. "Rao spin before drawdown"
      becomes `agitationAfter` on the final pour. "Never agitate" (April style)
      becomes both flags false everywhere, with pattern and flow doing the work.
    - Grind is an xBloom dial position, not microns. Lower is finer.

    ## 1. Pour-over methods and their pour structures

    ### 1.1 Tetsu Kasuya 4:6

    Divide total water into 40% (controls flavor) and 60% (controls strength).
    Ratio 1:15, medium-coarse grind, 93°C, ~3:25 total, 5 pours of equal volume,
    ~45 s between pours. Never start a pour before the bed surface runs dry.

    Flavor lever, within the first 40%: a larger first pour than second (80/40)
    gives brightness and acidity; equal (60/60) is balanced; a smaller first pour
    (40/80) gives sweetness and less acidity.

    Strength lever, within the last 60%: one large pour is lightest and cleanest;
    two pours are medium; three pours give the fullest body. More pours in the
    back half means more agitation events, which means more extraction and more
    body.

    ### 1.2 James Hoffmann V60

    Ratio 1:16.7, medium-fine, boiling for light roasts (15-20 s off boil for
    dark), ~3:30. Bloom 2x dose, agitate, rest to 0:45. Pour 1 takes the brew to
    60% of total water in one aggressive pass. Pour 2 adds the rest gently.
    Agitate again at the end to level the bed for an even drawdown.
    Front-loading like this pushes brightness and complexity.

    ### 1.3 Scott Rao V60

    Ratio 1:17, medium-fine, 95-100°C. Bloom ~3x dose with agitation to wet every
    ground. One or two main pours in concentric circles, the second starting as
    the water recedes halfway. Agitate at the end to flatten the bed. Minimal
    pours, evenness from agitation rather than from pulse count.

    ### 1.4 Melodrip / controlled agitation

    Ratio 1:16, medium grind, 93-96°C, ~4:30 including a long bloom. Bloom 4x
    dose, then four or more pours of 3-4x dose each. Pours are not clock-driven:
    the next one starts when the slurry drains to ~1 cm above the bed. Pours
    larger than 4x dose increase bypass. Smaller pours (3x) give a cleaner,
    slower, lighter-bodied cup. On this machine the equivalent is many small
    pours with dispersion-friendly patterns and agitation off.

    ### 1.5 Lance Hedrick 1-2-1

    Ratio 1:17, medium-fine, boiling, ~3:50. Bloom 3x dose, agitate hard, then
    rest a full two minutes so degassing finishes before extraction begins. One
    large main pour for the remainder. Agitate once near the end. The long bloom
    is the whole point: even extraction from a fully degassed bed. Hedrick's
    general answer to fines is a coarser grind plus more turbulence.

    ### 1.6 Osmotic flow (traditional Japanese)

    Ratio 1:12.5-1:15, coarse, 85-90°C, 3:00-4:00. Center pouring only, in a
    continuous trickle, never letting a slurry form. The dome of grounds acts as
    a membrane; extraction is driven by diffusion, not agitation. Maximum
    clarity. On this machine: many small center-pattern pours, no agitation.

    ### 1.7 April / Patrick Rolf

    Ratio 1:15-1:17, coarse, 92-99°C, 2:00-3:00, 4-5 equal pulse pours of ~50 ml.
    Never agitate at all — every bit of turbulence comes from the pour itself.
    Coarse grind plus many pulses gives a clean, tea-like cup.

    ### 1.8 Immersion-percolation hybrids

    Hario Switch and similar hold the bloom water in full contact instead of
    letting it drain, which raises bloom-phase extraction sharply. This machine
    cannot hold water, but the effect can be approached with a larger bloom and a
    longer pause.

    ### 1.9 SEY high-extraction, low-agitation

    Very fine grind, minimal agitation, 6-9 minutes, 24%+ extraction at ~1.37%
    TDS. The paradox: a fine grind makes abundant fines, but with no agitation
    they never migrate, so the bed does not clog. Longer than this machine's
    program range allows, but the principle — fine plus still — is usable.

    ### 1.10 Competition references

    - Martin Wolfl, 2024: OREA V4, 17 g / 270 ml, 93°C, 490 micron, 4 pours,
      natural anaerobic Geisha.
    - Carlos Medina, 2023: Origami Air S, 15.5 g / 250 ml, 91°C, 1:16, five equal
      50 ml pours at 30 s intervals, spiral out then in, 2:40 total, 65 ppm water.
    - Tetsu Kasuya, 2016: the 4:6 method, with a 50 g / 70 g split rather than
      equal halves for extra sweetness.

    ## 2. Bloom

    ### 2.1 Volume against dose

    2x dose is the standard. 3x for very fresh beans with aggressive degassing,
    or for a long bloom. 4x when the bloom has to saturate everything without
    agitation. 1.5x for stale beans with little CO2 left.

    ### 2.2 Freshness and bloom behavior

    - 1-3 days post-roast: explosive, hard to extract evenly. Bloom longer,
      45-60 s or more, and agitate less.
    - 4-14 days: a strong domed bloom, the ideal window. Standard 30-45 s.
    - 14-28 days: moderate. Standard bloom, slightly less water.
    - 28+ days: weak or absent. Less bloom water, 20-30 s, and grind finer to
      make up for how easily a stale bean gives up its solubles.

    ### 2.3 Degassing

    Roasting traps CO2 in the bean. About 40% escapes in the first day and most
    within 10-14 days, with slow seepage for weeks after. Until it is gone, CO2
    forms a gas barrier that repels water and makes extraction uneven — which is
    the entire reason the bloom exists. Dark roasts degas faster because the
    structure is more porous; light roasts hold CO2 longer. Grinding accelerates
    it dramatically.

    ### 2.4 Bloom time by roast

    Light 45-60 s, medium 30-45 s, dark 20-30 s. Dense beans hold more gas and
    release it slower.

    ### 2.5 Bloom agitation

    Agitating the bloom wets the bed evenly and breaks up clumps; on this machine
    that is `agitationAfter` on the bloom pour. Skip it for fragile, highly
    soluble, natural, or heavily fermented coffees where the risk is harshness,
    and let the pour pattern do the wetting instead.

    ## 3. Pour structure

    ### 3.1 What pour count does

    | Pours | Body | Clarity | Agitation | Suits |
    |---|---|---|---|---|
    | 1 | low-medium | high | low | clean, bright, Rao-like |
    | 2 | medium | high | low-medium | everyday, 1-2-1 |
    | 3 | medium | medium-high | medium | the most versatile |
    | 4-5 | medium-high | medium | medium-high | controlled flavor, 4:6 |
    | 6-8 | high | lower | high | full body, micro-pulse methods |

    ### 3.2 Distribution

    Front-loaded (60%+ by the end of the first main pour, Hoffmann): higher early
    extraction, more brightness and complexity, some channeling risk.

    Even (Kasuya, Medina): the most repeatable, the most balanced cup.

    Back-loaded: uncommon, and muddy if the bed has already collapsed.
    Occasionally useful for very light roasts needing extended contact.

    ### 3.3 Pour size

    Each pour is an agitation event in itself, whatever the agitation flags say.
    Many small pours mean more agitation, longer contact, higher extraction, more
    body — and more risk of fines migration. Few large pours mean a faster,
    cleaner brew at a lower extraction.

    ### 3.4 Temperature across the pours

    Pour-over loses heat continuously, and most extraction happens early while the
    slurry is hottest. Blind tests on light roasts found that dropping later pours
    to much cooler water made the cup thinner and less developed, so keep the
    temperature high throughout for light roasts. For dark roasts, dropping the
    last pour or two by 3-5°C measurably reduces astringency.

    ## 4. Reading the bean

    ### 4.1 Roast level

    | | Light | Medium | Dark |
    |---|---|---|---|
    | Temperature | 93-96°C | 90-93°C | 85-90°C |
    | Grind (xBloom dial) | 31-42 | 42-50 | 48-55 |
    | Bloom time | 45-60 s | 30-45 s | 20-30 s |
    | Bloom water | 3x dose | 2-3x dose | 2x dose |
    | Ratio | 1:16-1:18 | 1:15-1:16.5 | 1:14.5-1:16 |
    | Agitation | more | moderate | less |
    | Flow | 3.0 ml/s | 3.0-3.2 | 3.2-3.5 |
    | Pours | 3-5 | 2-4 | 2-3 |
    | RPM | 60-75 | 75-90 | 90-120 |

    Light roasts are dense and resist water; they need heat and energy. Dark
    roasts are porous and give everything up quickly; heat and agitation only
    fetch char and bitterness.

    ### 4.2 Process

    | | Washed | Natural | Honey |
    |---|---|---|---|
    | Temperature | higher end | lower end | middle |
    | Grind | finer | coarser | medium |
    | Ratio | 1:16-1:18 | 1:15-1:16.5 | 1:15-1:16.5 |
    | Agitation | tolerates more | keep minimal | moderate |
    | Pours | 3+ | 2-3 | 3 |

    Naturals are less dense, extract faster, and shed more fines when ground.
    Fewer pours and little agitation keep the fines where they are and keep
    astringency out. Washed coffees have uniform structure and take a finer grind
    and firmer handling without turning muddy.

    ### 4.3 Density and altitude

    Below 1200 m: low density, extracts easily, grind coarser and run cooler
    (88-92°C). 1200-1600 m: standard everything. Above 1600 m: dense, resists
    extraction, grind finer and run hotter (93-96°C). Dense beans also fracture
    more uniformly, which means fewer fines and a cleaner extraction.

    ### 4.4 Age

    | Age | Grind shift (xBloom dial) | Other |
    |---|---|---|
    | 1-3 days | +3 coarser | 60 s bloom, less agitation, higher ratio |
    | 4-7 days | +1-2 coarser | 45 s bloom |
    | 7-21 days | none | peak window |
    | 21-35 days | none to -1 finer | standard |
    | 35-60 days | -2 finer | 25-30 s bloom, hotter water |
    | 60+ days | -3 finer | shortest bloom, hottest water, more agitation |

    Rest before use scales with roast: light 7-14 days, medium 5-10, dark 2-5.

    ### 4.5 Single origin against blends

    A single origin can be pushed toward its own strengths. A blend has already
    been balanced by the roaster; use middle-ground parameters and avoid extremes
    of any one variable.

    ## 5. Extraction concepts

    ### 5.1 Percolation against immersion

    This machine percolates. Fresh water continually replaces the extracted
    solution, which keeps the concentration gradient steep and the extraction
    efficient — typically 18-22% yield, brighter and cleaner than immersion, with
    fast-extracting acids and sugars over-represented relative to bitter
    compounds.

    ### 5.2 Fines migration and channeling

    Fines are sub-100-micron particles made during grinding. Water carries them
    down onto the filter, where they clog it, slow the drawdown, and push water
    into channels — over-extracting some of the bed while leaving the rest raw.
    Agitation accelerates the migration. That is the central tension: agitation
    makes extraction more even and clogging more likely. The two stable answers
    are a fine grind with almost no agitation, or a coarse grind with plenty.
    Coarse grinds tolerate agitation; fine grinds do not.

    ### 5.3 Grind against agitation

    They are different levers, not two dials for the same thing. A finer grind
    adds surface area permanently and extracts more uniformly from every
    particle. Agitation refreshes the gradient at the particle surface and
    extracts more evenly across the bed as a whole. Hotter water speeds
    everything, including the bitter compounds. Longer contact adds extraction
    and, eventually, astringency.

    ## 6. Ratio

    | Ratio | Strength | Suits |
    |---|---|---|
    | 1:14.5 | strong | dark roasts, espresso-like intensity |
    | 1:15 | strong-medium | full body, 4:6, naturals |
    | 1:16 | balanced | the competition standard, most versatile |
    | 1:17 | clean-medium | Hoffmann and Rao style, washed coffees |
    | 1:18 | clean-light | tea-like, delicate |

    By origin tendency: washed Ethiopian 1:16-1:17.5 so the florals breathe;
    natural Ethiopian 1:15-1:16 to concentrate the berry sweetness; Colombian
    1:15-1:16; Kenyan 1:16-1:17.5 for juicy clarity; Geisha and other delicate
    lots 1:17-1:18.5; Brazilian 1:15-1:16; Indonesian 1:14.5-1:15.

    ## 7. Grind on the xBloom dial

    Lower is finer. The pour-over band is 31-55.

    | Range | Character | Suits |
    |---|---|---|
    | 31-38 | fine | dense light roasts, washed, high grown, high extraction |
    | 38-45 | fine-medium | light to medium, most single origins |
    | 45-50 | medium | the versatile middle, medium roasts, blends |
    | 50-55 | medium-coarse | dark roasts, naturals, 4:6, pulse methods |

    ## 8. Pour pattern

    Center is gentlest: it wets a narrow column and agitates least, which is what
    bloom and osmotic-flow methods want. Circular saturates evenly and is the
    default for main pours. Spiral covers the most surface and agitates most,
    which suits a main pour that needs to move the bed.

    ## 9. Flow rate

    3.0 ml/s is gentler and gives more contact time — the choice for fine grinds
    and light roasts. 3.5 ml/s is faster with less contact, which keeps coarser
    grinds and darker roasts from over-extracting.

    ## 10. Grinder RPM

    60-75 generates the least heat and preserves delicate aromatics; use it for
    light roasts and anything floral. 75-90 is the all-rounder. 90-120 grinds
    fast and is fine for medium and dark roasts.

    ## 11. Diagnosing a cup

    Sour, thin, salty means under-extracted: grind finer, raise the temperature,
    add agitation, lengthen the bloom, slow the flow.

    Bitter, astringent, drying means over-extracted: grind coarser, lower the
    temperature, cut agitation, shorten the bloom, speed the flow.

    Sweet, balanced, clean-finishing is the target, 18-22% yield. Acids extract
    first, sugars second, bitter compounds last. The whole craft is to extract
    through the sweetness and stop before the bitterness.

    Levers ranked by how much they move the cup: grind size, then temperature,
    then pour structure, then agitation, then flow rate.

    ## 12. Origin flavor tendencies

    | Origin | Typical notes | Tendency |
    |---|---|---|
    | Ethiopian washed | floral, tea-like, jasmine, bergamot | hotter, finer, gentle |
    | Ethiopian natural | fruity, berry, wine-like | moderate temp, medium grind, low agitation |
    | Colombian | balanced, nutty, caramel, chocolate | flexible, works with anything |
    | Kenyan | bright, juicy, blackcurrant, tomato | hotter, slower flow for sweetness |
    | Brazilian | nutty, chocolate, low acidity | cooler, coarser |
    | Sumatran | earthy, heavy body, herbal | cooler, fewer pours |
    | Guatemalan | chocolate, spice, medium body | moderate everything |
    | Costa Rican | honey, citrus, clean | medium-high temp, standard three pours |
    | Rwandan | fruity, floral, complex | like washed Ethiopian |
    | Panamanian Geisha | delicate, tea-like, extraordinary florals | hottest, finest, gentlest |
    | Yemeni | fruity, complex, spicy, wine-like | cooler, medium grind, gentle |
    """
}
