"""gen_allergen_table.py - one-shot generator for meal-prep/db/allergens.json (backlog I144).

Kept in the tree rather than run from scratch because the table it writes is reader-safety data:
the next person to add an allergen assignment should see how the existing 350-odd were made, and
the completeness assertion at the bottom is the thing that makes a rerun safe. It writes the file
whole from the dict below, so EDIT THE DICT, never the JSON, and rerun.

The classification rule is stated in the file's own `rule` field and in meal-prep/lib/allergen-lib.ps1.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
ING = os.path.join(MP, "db", "ingredients.json")
OUT = os.path.join(MP, "db", "allergens.json")

# The nine, in the order FALCPA/FASTER name them. The card renders them in this order so the line
# is scannable and stable across recipes.
NINE = [
    {"key": "milk", "label": "milk"},
    {"key": "eggs", "label": "eggs"},
    {"key": "fish", "label": "fish", "names_species": True},
    {"key": "shellfish", "label": "shellfish", "names_species": True},
    {"key": "tree_nuts", "label": "tree nuts", "names_species": True},
    {"key": "peanuts", "label": "peanuts"},
    {"key": "wheat", "label": "wheat"},
    {"key": "soy", "label": "soy"},
    {"key": "sesame", "label": "sesame"},
]

# Hidden sources: the allergen is real but nothing in the ingredient's NAME says so. The value is the
# clause the card prints after "<allergen>, from ...", so it reads as a sentence.
H_WORCESTER = {"fish": "the anchovies in Worcestershire sauce"}
H_OYSTER = {"shellfish": "the oysters in oyster sauce"}
H_SOYSAUCE = {"wheat": "the wheat soy sauce is brewed with"}
H_CURRY = {"shellfish": "the shrimp paste in Thai curry paste"}

# item -> (allergen tokens, hidden clauses). A token is a bare key from NINE, or key:specific where
# the specific food is named (required for tree nuts, shellfish and fish).
T = {
    "1/3 Fat Cream Cheese": (["milk"], {}),
    "93/7 Ground Beef": ([], {}),
    "93/7 Ground Turkey": ([], {}),
    "99/1 Ground Turkey": ([], {}),
    "Achiote Paste": ([], {}),
    "Aji Amarillo Paste": ([], {}),
    "Alfredo Sauce": (["milk"], {}),
    "All-Purpose Flour": (["wheat"], {}),
    "Almonds": (["tree_nuts:almond"], {}),
    "Apple": ([], {}),
    "Apple Cider": ([], {}),
    "Apple Cider Vinegar": ([], {}),
    "Apple Juice": ([], {}),
    "Artichoke Hearts": ([], {}),
    "Avocado": ([], {}),
    "Au Jus Gravy Mix": (["wheat", "soy"], {"wheat": "the flour a gravy mix is thickened with", "soy": "the hydrolyzed soy protein in a gravy mix"}),
    "Baked Beans": ([], {}),
    "Baking Powder": ([], {}),
    "Baking Soda": ([], {}),
    "Balsamic Vinegar": ([], {}),
    "Basil Pesto": (["milk", "tree_nuts:pine nut"], {"tree_nuts": "the pine nuts in pesto"}),
    "Bay Leaves": ([], {}),
    "BBQ Sauce": ([], {}),
    "BBQ Sauce (Sugar Free)": ([], {}),
    "Beef Broth": ([], {}),
    "Beef Chuck Roast": ([], {}),
    "Beef Flank/Sirloin Steak": ([], {}),
    "Berbere Seasoning": ([], {}),
    "Black Pepper": ([], {}),
    "Blackberries": ([], {}),
    "Boneless Skinless Chicken Breast": ([], {}),
    "Boneless Skinless Chicken Thigh": ([], {}),
    "Bratwurst": ([], {}),
    "Bread Crumbs": (["wheat"], {}),
    "Broccoli Florets": ([], {}),
    "Brown Gravy Mix": (["wheat", "soy"], {"wheat": "the flour a gravy mix is thickened with", "soy": "the hydrolyzed soy protein in a gravy mix"}),
    "Brown Sugar": ([], {}),
    "Brussels Sprouts": ([], {}),
    "Buffalo Wing Sauce": (["milk"], {"milk": "the butter in buffalo wing sauce"}),
    "Bulgur Wheat": (["wheat"], {}),
    "Butter": (["milk"], {}),
    "Butter Crackers": (["wheat", "soy"], {"soy": "the soybean oil crackers are baked with"}),
    "Cajun Seasoning": ([], {}),
    "Canned Black Beans": ([], {}),
    "Canned Pinto Beans": ([], {}),
    "Cannellini Beans": ([], {}),
    "Capers": ([], {}),
    "Caraway Seeds": ([], {}),
    "Carrots": ([], {}),
    "Cashews": (["tree_nuts:cashew"], {}),
    "Cayenne Pepper": ([], {}),
    "Celery": ([], {}),
    "Celery Salt": ([], {}),
    "Cheddar Cheese": (["milk"], {}),
    "Cheddar Cheese, Shredded": (["milk"], {}),
    "Cheese Tortellini": (["milk", "eggs", "wheat"], {}),
    "Cherry Tomatoes": ([], {}),
    "Chicken Broth": ([], {}),
    "Chicken Livers": ([], {}),
    "Chickpeas": ([], {}),
    "Chili Crisp": (["soy"], {"soy": "the soybeans and soybean oil in chili crisp"}),
    "Chili Crisp / Chili Oil": (["soy"], {"soy": "the soybeans and soybean oil in chili crisp"}),
    "Chili Powder": ([], {}),
    "Chipotle in Adobo": ([], {}),
    "Cocoa Powder": ([], {}),
    "Coconut Milk": (["tree_nuts:coconut"], {"tree_nuts": "coconut, which the FDA lists as a tree nut"}),
    "Condensed French Onion Soup": (["wheat", "soy"], {"wheat": "the wheat in condensed soup", "soy": "the soy protein in condensed soup"}),
    "Corn Chips": ([], {}),
    "Corn Muffin Mix": (["wheat"], {}),
    "Corn Tortillas": ([], {}),
    "Corned Beef Brisket": ([], {}),
    "Cornstarch": ([], {}),
    "Cottage Cheese": (["milk"], {}),
    "Cream of Chicken Soup": (["milk", "wheat", "soy"], {"wheat": "the flour a cream soup is thickened with", "soy": "the soy protein in condensed soup"}),
    "Cream of Mushroom Soup": (["milk", "wheat", "soy"], {"wheat": "the flour a cream soup is thickened with", "soy": "the soy protein in condensed soup"}),
    "Crushed Tomatoes": ([], {}),
    "Cucumber": ([], {}),
    "Curry Powder": ([], {}),
    "Diced Green Chiles": ([], {}),
    "Diced Ham": ([], {}),
    "Diced Tomatoes": ([], {}),
    "Diced Tomatoes & Green Chilies": ([], {}),
    "Dijon Mustard": ([], {}),
    "Dill Pickles": ([], {}),
    "Doubanjiang": (["soy", "wheat"], {"soy": "the fermented soybeans in doubanjiang", "wheat": "the wheat flour in doubanjiang"}),
    "Dried Ancho Chiles": ([], {}),
    "Dried Arbol Chiles": ([], {}),
    "Dried Basil": ([], {}),
    "Dried Dill": ([], {}),
    "Dried Guajillo Chiles": ([], {}),
    "Dried Oregano": ([], {}),
    "Dried Parsley": ([], {}),
    "Dried Rosemary": ([], {}),
    "Dried Thyme": ([], {}),
    "Egg Noodles": (["eggs", "wheat"], {}),
    "Eggplant": ([], {}),
    "Eggs": (["eggs"], {}),
    "Enchilada Sauce": ([], {}),
    "Fajita Seasoning": ([], {}),
    "Fat Free Cheddar": (["milk"], {}),
    "Fat Free Cottage Cheese": (["milk"], {}),
    "Feta Cheese": (["milk"], {}),
    "Fettuccine": (["wheat"], {}),
    "Fish Sauce": (["fish:anchovy"], {}),
    "Five-Spice Powder": ([], {}),
    "Fresh Basil": ([], {}),
    "Fresh Cilantro": ([], {}),
    "Fresh Mint": ([], {}),
    "Fries": ([], {}),
    "Frozen Chopped Spinach": ([], {}),
    "Frozen Green Peas": ([], {}),
    "Frozen Hash Browns": ([], {}),
    "Frozen Peas": ([], {}),
    "Garam Masala": ([], {}),
    "Garlic": ([], {}),
    "Garlic Powder": ([], {}),
    "Ginger": ([], {}),
    "Gingersnap Cookies": (["wheat", "soy"], {"soy": "the soybean oil cookies are baked with"}),
    "Gochujang": (["soy", "wheat"], {"soy": "the fermented soybeans in gochujang", "wheat": "the wheat in gochujang"}),
    "Golden Raisins": ([], {}),
    "Greek Yogurt": (["milk"], {}),
    "Green Beans": ([], {}),
    "Green Bell Peppers": ([], {}),
    "Green Cabbage": ([], {}),
    "Green Chile Sauce": ([], {}),
    "Green Olives": ([], {}),
    "Green Onions": ([], {}),
    "Grits": ([], {}),
    "Ground Allspice": ([], {}),
    "Ground Cinnamon": ([], {}),
    "Ground Cloves": ([], {}),
    "Ground Coriander": ([], {}),
    "Ground Cumin": ([], {}),
    "Ground Fennel": ([], {}),
    "Ground Ginger": ([], {}),
    "Ground Nutmeg": ([], {}),
    "Ground Pork": ([], {}),
    "Ground Turmeric": ([], {}),
    "Half and Half": (["milk"], {}),
    "Harissa Paste": ([], {}),
    "Heavy Cream": (["milk"], {}),
    "Hickory Smoked Bacon": ([], {}),
    "High Fiber Tortilla": (["wheat"], {}),
    "Hoisin Sauce": (["soy", "wheat"], {"soy": "the fermented soybeans in hoisin", "wheat": "the wheat flour in hoisin"}),
    "Hominy": ([], {}),
    "Honey": ([], {}),
    "Honey Dijon Mustard": ([], {}),
    "Horseradish Sauce": (["eggs"], {"eggs": "the egg yolk in a creamy horseradish sauce"}),
    "Hot Honey": ([], {}),
    "Hot Italian Sausage": ([], {}),
    "Hot Sauce": ([], {}),
    "Hummus": (["sesame"], {"sesame": "the tahini in hummus"}),
    "Italian Seasoning": ([], {}),
    "Jalapeno": ([], {}),
    "Japanese Curry Roux": (["wheat", "milk", "soy"], {"wheat": "the flour a curry roux block is made from", "milk": "the milk solids in a curry roux block", "soy": "the soy in a curry roux block"}),
    "Jerk Seasoning": ([], {}),
    "Kale": ([], {}),
    "Ketchup": ([], {}),
    "Keto Bun": (["wheat", "eggs"], {"wheat": "the wheat protein most keto buns are built on"}),
    "Kidney Beans": ([], {}),
    "Korean Rice Cakes": ([], {}),
    "Lemon Juice": ([], {}),
    "Lemongrass Paste": ([], {}),
    "Light Sour Cream": (["milk"], {}),
    "Lime Juice": ([], {}),
    "Liquid Smoke": ([], {}),
    "Lo Mein Noodles": (["wheat"], {}),
    "Mango": ([], {}),
    "Marinara Sauce": ([], {}),
    "Mayonnaise": (["eggs"], {}),
    "Mexican Cheese Blend": (["milk"], {}),
    "Milk": (["milk"], {}),
    "Mirin": ([], {}),
    "Miso Paste": (["soy"], {"soy": "the fermented soybeans miso is made from"}),
    "Mole Paste": (["tree_nuts:almond", "peanuts", "wheat", "sesame"], {"tree_nuts": "the almonds in mole", "peanuts": "the peanuts in mole", "wheat": "the crackers or bread thickening the mole", "sesame": "the sesame seeds in mole"}),
    "Monterey Jack Cheese": (["milk"], {}),
    "Mozzarella Cheese": (["milk"], {}),
    "Olive Oil": ([], {}),
    "Olives": ([], {}),
    "Onion Powder": ([], {}),
    "Onion Soup Mix": (["soy"], {"soy": "the hydrolyzed soy protein in a soup mix"}),
    "Orange Juice": ([], {}),
    "Orange Zest": ([], {}),
    "Orzo Pasta": (["wheat"], {}),
    "Oyster Sauce": (["shellfish:oyster"], H_OYSTER),
    "Panko Breadcrumbs": (["wheat"], {}),
    "Paprika": ([], {}),
    "Parmesan Cheese": (["milk"], {}),
    "Pasta Shells": (["wheat"], {}),
    "Pasta Shells - jumbo": (["wheat"], {}),
    "Peanut Butter": (["peanuts"], {}),
    "Peanuts": (["peanuts"], {}),
    "Penne Pasta": (["wheat"], {}),
    "Pepperoncini": ([], {}),
    "Pigeon Peas": ([], {}),
    "Pineapple Chunks": ([], {}),
    "Pineapple Juice": ([], {}),
    "Plain Yogurt": (["milk"], {}),
    "Poblano Peppers": ([], {}),
    "Pomegranate Molasses": ([], {}),
    "Poppy Seeds": ([], {}),
    "Pork Chops": ([], {}),
    "Pork Chorizo": ([], {}),
    "Pork Loin": ([], {}),
    "Pork Shoulder": ([], {}),
    "Pork Tenderloin": ([], {}),
    "Potato": ([], {}),
    "Potato Gnocchi": (["wheat"], {"wheat": "the wheat flour binding potato gnocchi"}),
    "Poultry Seasoning": ([], {}),
    "Provolone Cheese": (["milk"], {}),
    "Pumpkin Puree": ([], {}),
    "Ranch Dressing": (["milk", "eggs"], {}),
    "Ranch Seasoning Mix": (["milk"], {"milk": "the buttermilk powder in a ranch mix"}),
    "Red Bell Pepper": ([], {}),
    "Red Curry Paste": (["shellfish:shrimp"], H_CURRY),
    "Red Onion": ([], {}),
    "Red Pepper Flakes": ([], {}),
    "Red Wine Vinegar": ([], {}),
    "Reduced Fat Mozzarella": (["milk"], {}),
    "Refried Beans": ([], {}),
    "Refrigerated Biscuits": (["wheat", "milk"], {"milk": "the buttermilk in refrigerated biscuits"}),
    "Rice": ([], {}),
    "Rice Noodles": ([], {}),
    "Rice Vinegar": ([], {}),
    "Ricotta Cheese": (["milk"], {}),
    "Roasted Red Peppers": ([], {}),
    "Rotini Pasta": (["wheat"], {}),
    "Rotisserie Chicken": ([], {}),
    "Rye Bread": (["wheat"], {"wheat": "the wheat flour rye bread is mostly made of"}),
    "Salsa": ([], {}),
    "Salsa Verde": ([], {}),
    "Salt": ([], {}),
    "Sandwich Bread": (["wheat"], {}),
    "Sauerkraut": ([], {}),
    "Sazon Seasoning": ([], {}),
    "Seasoned Black Beans": ([], {}),
    "Sesame Oil": (["sesame"], {}),
    "Shallots": ([], {}),
    "Shredded Carrots": ([], {}),
    "Smoked Paprika": ([], {}),
    "Smoked Turkey Sausage": ([], {}),
    "Snow Peas": ([], {}),
    "Soy Sauce": (["soy", "wheat"], H_SOYSAUCE),
    "Spaghetti": (["wheat"], {}),
    "Spinach": ([], {}),
    "Sriracha": ([], {}),
    "Stuffing Mix": (["wheat", "soy"], {"soy": "the soybean oil in a stuffing mix"}),
    "Sugar": ([], {}),
    "Sugar-Free Maple Syrup": ([], {}),
    "Sumac": ([], {}),
    "Sun-Dried Tomatoes": ([], {}),
    "Sweet Chili Sauce": ([], {}),
    "Sweet Potatoes": ([], {}),
    "Sweet Soy Sauce": (["soy", "wheat"], H_SOYSAUCE),
    "Sweet Whole Kernel Corn": ([], {}),
    "Swiss Cheese": (["milk"], {}),
    "Taco Seasoning": ([], {}),
    "Tahini": (["sesame"], {}),
    "Tater Tots": ([], {}),
    "Teriyaki Sauce": (["soy", "wheat"], H_SOYSAUCE),
    "Toasted Sesame Seeds": (["sesame"], {}),
    "Tomatillos": ([], {}),
    "Tomato Paste": ([], {}),
    "Tomato Sauce": ([], {}),
    "Tortilla": (["wheat"], {}),
    "Traditional Pasta Sauce": ([], {}),
    "Turkey Bacon": ([], {}),
    "Turkey Breast": ([], {}),
    "Turkey Pepperoni": ([], {}),
    "Vegetable Oil": ([], {}),
    "Walnuts": (["tree_nuts:walnut"], {}),
    "White Mushrooms": ([], {}),
    "White Vinegar": ([], {}),
    "White Wine Vinegar": ([], {}),
    "Wild Rice": ([], {}),
    "Worcestershire Sauce": (["fish:anchovy"], H_WORCESTER),
    "Yellow Onion": ([], {}),
    "Zero-Sugar Soda": ([], {}),
    "Ziti Pasta": (["wheat"], {}),
    "Zucchini": ([], {}),
    "Korean glass noodles (dangmyeon)": ([], {}),
    "Cauliflower": ([], {}),
    "Fresh Parsley": ([], {}),
    "Fresh Oregano": ([], {}),
    "Dry White Wine": ([], {}),
    "Pepper Jack Cheese": (["milk"], {}),
    "Gruyere Cheese": (["milk"], {}),
    "80/20 Ground Beef": ([], {}),
    "Shaved Beef Steak": ([], {}),
    "Pork Smoked Sausage": ([], {}),
    "Portobello Mushrooms": ([], {}),
    "Brandy": ([], {}),
    "Broccolini": ([], {}),
    "Beef Base": (["soy"], {"soy": "the hydrolyzed soy protein in a bouillon base"}),
    "Egg Yolk": (["eggs"], {}),
    "Sun-Dried Tomatoes (Oil-Packed)": ([], {}),
    "Boneless Beef Short Ribs": ([], {}),
    "Yellow Bell Pepper": ([], {}),
    "Yellow Mustard": ([], {}),
    "Broccoli": ([], {}),
    "Black Olives": ([], {}),
    "Fresh Rosemary": ([], {}),
    "Fresh Sage": ([], {}),
    "Fresh Cranberries": ([], {}),
    "Spaghetti Squash": ([], {}),
    "Whole Chicken": ([], {}),
    "Lemons": ([], {}),
    "Fresh Thyme": ([], {}),
    "Dry Red Wine": ([], {}),
    "Bell Peppers": ([], {}),
    "Shredded Cheese": (["milk"], {}),
    "Lime": ([], {}),
    "Sea Salt": ([], {}),
    "Almond Butter": (["tree_nuts:almond"], {}),
    "Masa Harina": ([], {}),
    "Fresh Mozzarella": (["milk"], {}),
    "Boursin Cheese": (["milk"], {}),
    "Bone Broth": ([], {}),
    "High Protein Pasta": (["wheat"], {}),
    "Frozen Lightly Breaded Chicken Breast Bites": (["wheat"], {"wheat": "the breading on the chicken bites"}),
    "No-Boil Lasagna Noodles": (["wheat"], {}),
    "Cotija Cheese": (["milk"], {}),
    "Fresh Lemon Juice": ([], {}),
    "Lemon Zest": ([], {}),
    "Lime Zest": ([], {}),
    "Coconut Oil": ([], {}),
    "Cooking Spray": ([], {}),
    "Cranberry Sauce": ([], {}),
    "Fresh Red Chili": ([], {}),
    "Blackened Seasoning": ([], {}),
    "Romaine Lettuce": ([], {}),
    "Cilantro Lime Rice": ([], {}),
    "Fresh Lime Juice": ([], {}),
    "Apricot Jam": ([], {}),
    "Light Mayonnaise": (["eggs"], {}),
    "Cooked White Rice": ([], {}),
    "Reduced Fat Cheddar Cheese": (["milk"], {}),
    "Adobo Seasoning": ([], {}),
    "Deli Ham": ([], {}),
    "Dill Pickle Slices": ([], {}),
    "Pepperoni": ([], {}),
    "Sour Cream": (["milk"], {}),
    "Smoked Sausage": ([], {}),
    "Andouille Smoked Sausage": ([], {}),
    "Tandoori Masala": ([], {}),
    "Baby Potatoes": ([], {}),
    "Whole Wheat Flour": (["wheat"], {}),
    "Frozen Cauliflower Rice": ([], {}),
    "Fat Free Mozzarella": (["milk"], {}),
    "Mustard Powder": ([], {}),
    "Bok Choy": ([], {}),
    "Bean Sprouts": ([], {}),
    "Tomatoes": ([], {}),
}

# Rows in the ingredient map that are not foods. They carry no classification and no spec may use
# them; the completeness check below names any row that is neither classified nor listed here.
NOT_A_FOOD = ["_r300_note"]

README = (
    "ALLERGEN CLASSIFICATION for every row of db/ingredients.json, one entry per ingredient-map item "
    "name. Brad's ruling, 2026-09-12, backlog I144: every recipe card carries a generated 'Contains' "
    "line over the nine major US allergens, naming the specific nut, shellfish or fish, and calling "
    "out hidden sources. The line is NEVER hand-written: meal-prep/lib/allergen-lib.ps1 derives it "
    "from this table by the spec's own scaler ingredient names, build-card2.ps1 renders it, and "
    "pipeline/audit-allergen-line.ps1 refuses a card whose line is missing or disagrees. "
    "EDIT pipeline/gen_allergen_table.py AND RERUN IT; do not hand-edit this file, because the "
    "generator is what proves every map row is covered."
)

RULE = (
    "An allergen is listed when it is inherent to the food the ingredient NAMES: the food cannot be "
    "that food without it, or the standard US supermarket formulation of that named product carries "
    "it as a defining component. An allergen only SOME brands add is not listed, because that is a "
    "guess rather than a derivation, and the card's own note is what covers it: the line reflects the "
    "recipe as written, and the reader checks the label on the brand they buy. Two consequences worth "
    "stating because they look like omissions. (1) Refined oils are exempt from FALCPA allergen "
    "labelling, so soybean oil alone does not make a row soy. (2) 'May contain' is not recognised by "
    "FALCPA and is purely voluntary, so it never appears here. Coconut IS listed as a tree nut "
    "because the FDA's tree-nut list includes it; the card names the specific nut, so a reader "
    "allergic to almonds is not misled by a coconut recipe."
)


def main():
    with open(ING, encoding="utf-8") as fh:
        rows = json.load(fh)
    names = [r["item"] for r in rows]

    # COMPLETENESS, and it is the whole reason this generator exists. A map row with no entry would
    # otherwise render as "contains nothing", which is the agreeing-zero shape: a silent, confident,
    # wrong answer on a reader-safety line.
    missing = [n for n in names if n not in T and n not in NOT_A_FOOD]
    extra = [n for n in T if n not in names]
    if missing:
        raise SystemExit("UNCLASSIFIED ingredient-map rows (%d): %s" % (len(missing), ", ".join(missing)))
    if extra:
        raise SystemExit("classified rows that are not in the ingredient map (%d): %s" % (len(extra), ", ".join(extra)))

    keys = {a["key"] for a in NINE}
    items = {}
    for n in names:
        if n in NOT_A_FOOD:
            continue
        toks, hidden = T[n]
        for t in toks:
            k = t.split(":", 1)[0]
            if k not in keys:
                raise SystemExit("%s: '%s' is not one of the nine" % (n, t))
        for k in hidden:
            if k not in [t.split(":", 1)[0] for t in toks]:
                raise SystemExit("%s: hidden '%s' is not in its own contains list" % (n, k))
        e = {"contains": toks}
        if hidden:
            e["hidden"] = hidden
        items[n] = e

    doc = {
        "readme": README,
        "ruling": "Brad, 2026-09-12, backlog I144. See design/RULING-allergen-line-2026-09-12.md.",
        "rule": RULE,
        "generated_by": "meal-prep/pipeline/gen_allergen_table.py",
        "allergens": NINE,
        "not_a_food": NOT_A_FOOD,
        "items": items,
    }
    text = json.dumps(doc, indent=2, ensure_ascii=True, sort_keys=False) + "\n"
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    n_with = sum(1 for v in items.values() if v["contains"])
    n_hidden = sum(1 for v in items.values() if v.get("hidden"))
    print("allergens.json: %d item(s) classified, %d carry at least one of the nine, %d carry a hidden source"
          % (len(items), n_with, n_hidden))
    print("GEN-ALLERGEN-TABLE-COMPLETE items=%d classified=%d hidden=%d" % (len(items), n_with, n_hidden))


if __name__ == "__main__":
    main()
