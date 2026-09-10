// Original synthetic material, authored for this experiment under the repository
// Apache-2.0 license. No corpus, scraped pages, emails, or private input is read.
const line = (text, label = 'paragraph') => ({ text, label });
const h = text => line(text, 'heading');
const l = text => line(text, 'list');
const q = text => line(text, 'quote');
const c = text => line(text, 'code');
const t = text => line(text, 'table');
const p = line;
const blank = () => p('');
export function trainingFixtures() {
  const docs = [];
  const foods = ['Lemon Rice', 'Bean Soup', 'Roasted Carrots', 'Apple Crumble', 'Lentil Stew', 'Tomato Salad', 'Oat Biscuits', 'Herbed Potatoes'];
  const ingredients = ['rice', 'beans', 'carrots', 'apples', 'lentils', 'tomatoes', 'oats', 'potatoes'];
  for (let i = 0; i < 80; i++) {
    const food = foods[i % foods.length];
    const ingredient = ingredients[i % ingredients.length];
    const amount = ['1/2', '2', '¾', '1 1/2', '250', '0.25', '⅓', '3'][i % 8];
    const domain = 'recipe';
    docs.push({ id: `train-recipe-${i}`, split: 'train', domain, family: `recipe-${i % 2}`, lines: i % 2 ? [
      h(food), blank(), p(`This ${ingredient} dish serves ${i % 5 + 2} people.`), h('Ingredients:'),
      l(`${amount} cups ${ingredient}`), l('1 tsp salt'), l('Pepper to taste'), blank(), h('Directions'),
      l('1. Mix the ingredients gently.'), l(`2. Cook for ${10 + i} minutes.`), p('Keep leftovers in a covered dish.'),
    ] : [h(`Easy ${food}`), h('INGREDIENTS'), l(`- ${amount} g ${ingredient}`), l('- 2 tbsp oil'),
      h('Method'), p(`Warm the pan, then add the ${ingredient}.`), p(`Stir for ${5 + i} minutes and serve.`), h('Notes'), p('Do not change the amount of liquid.') ] });
    docs.push({ id: `train-email-${i}`, split: 'train', domain: 'email', family: `email-${i % 2}`, lines: i % 2 ? [
      p(`From: Person ${i} <person${i}@example.test>`), p(`Subject: Planning update ${i}`), blank(), p('Hello team,'),
      p(`We need to review ${i + 2} documents by Friday.`), h('Next steps:'), l('- Read the draft'), l('- Reply with comments'),
      blank(), q('> Can we discuss this next week?'), q('> The previous deadline was Monday.'), p('Thank you,'), p(`Person ${i}`),
    ] : [p(`To: team${i}@example.test`), p(`Subject: Re: delivery ${i}`), p('Good morning,'), p(`The order contains ${i + 1} boxes.`),
      p('Here is the previous message:'), q('> The shipment arrived.'), q('> Please confirm the item count.'), blank(), p('Best regards,'), p('Morgan')] });
    docs.push({ id: `train-web-${i}`, split: 'train', domain: 'webpage', family: `web-${i % 2}`, lines: i % 2 ? [
      h(`Garden Guide ${i}`), blank(), p(`Our garden has ${i + 2} varieties of plants.`), h('SUPPLIES'),
      l('• gloves'), l('• small spade'), h('Measurements'), t('Item\tCount\tUnit'), t(`Seeds\t${i + 1}\tpackets`),
      p('The sample command is below.'), c(`    const total = ${i + 3};`), c('    console.log(total);'), p('https://example.test/garden'),
    ] : [h(`# Device Manual ${i}`), p('Read all instructions before assembly.'), h('Example'), c(`let count = ${i};`),
      c('if (count > 0) {'), c('  count += 1;'), c('}'), h('Reference'), t('| Name | Value |'), t(`| Capacity | ${i + 10} |`),
      q('> Always keep this manual.'), p('Further information: https://example.test/manual')] });
  }
  return docs;
}
// Distinct document templates and vocabulary from training. Threshold selection
// reads these validation documents only; test labels never affect training.
export const validationFixtures = [
  { id: 'valid-recipe', domain: 'recipe', family: 'valid-recipe', lines: [h('Coconut Pudding'), p('Serves 4.'), h('You will need'), l('300 ml coconut milk'), l('2 tablespoons starch'), l('A pinch of sugar'), h('Preparation'), p('Whisk everything together. Simmer until thick.'), p('Cool for 20 minutes.')] },
  { id: 'valid-email', domain: 'email', family: 'valid-email', lines: [p('From: editor@example.test'), p('Subject: Your revised draft'), p('Hi Rowan,'), p('Thanks for sending the file.'), h('Requested changes'), l('1) Check page 12.'), l('2) Add the reference.'), q('> Is the title correct?'), p('Regards,'), p('Alex')] },
  { id: 'valid-web', domain: 'webpage', family: 'valid-web', lines: [h('Sensor Calibration'), p('Use these values as examples only.'), h('Output'), t('Channel\tOffset'), t('A\t0.125'), t('B\t-0.25'), c('    print("ready")'), q('> Keep the sensor dry.'), p('See https://example.test/sensors.')] },
  { id: 'valid-recipe-2', domain: 'recipe', family: 'valid-recipe-2', lines: [h('NO KNEAD BREAD'), l('400g flour'), l('7g yeast'), l('350ml water'), blank(), p('Mix and leave overnight.'), p('Bake at 220°C for 35 minutes.'), p('Salt is optional.')] },
  { id: 'valid-email-2', domain: 'email', family: 'valid-email-2', lines: [p('Subject: RECEIPT'), p('Invoice 2468'), p('Amount: 19.95'), p('Paid on Tuesday.'), blank(), p('Support'), p('https://example.test/support')] },
  { id: 'valid-web-2', domain: 'webpage', family: 'valid-web-2', lines: [h('Working with Files'), h('Quick start'), c('    open("demo.txt")'), p('The function opens a local file.'), l('1. Select a directory.'), l('2. Choose a filename.'), t('| Mode | Meaning |'), t('| r | Read |')] },
].map(doc => ({ ...doc, split: 'validation' }));

// Separately authored held-out layouts; never parameter variants of train or
// validation documents. Some labels are inherently underdetermined without DOM.
export const heldOutFixtures = [
  { id: 'test-recipe-01', domain: 'recipe', lines: [h('Chickpea skillet'), p('Prep 12 min • Cook 18 min'), h('What goes in'), l('1½ cans chickpeas, drained'), l('2–3 tbsp olive oil'), l('½ lemon, juice only'), l('Salt to taste'), h('How to make it'), p('Heat oil. Add chickpeas and cook for 18 minutes.'), p('Finish with lemon; do not add water.')] },
  { id: 'test-recipe-02', domain: 'recipe', lines: [h('Pear compote'), p('Makes about 600 ml'), l('4 pears (about 750g)'), l('60 g sugar'), l('⅛ tsp cloves'), blank(), l('1) Peel and chop pears.'), l('2) Add sugar and 120 ml water.'), l('3) Simmer, covered, 15–20 min.'), p('Source: https://example.test/pear?serves=4')] },
  { id: 'test-recipe-03', domain: 'recipe', lines: [h('Dressing'), l('30ml vinegar'), l('90ml oil'), l('1 small shallot'), p('Whisk; taste before adding salt.'), h('Optional additions'), l('A little chopped dill'), l('Freshly ground pepper')] },
  { id: 'test-recipe-04', domain: 'recipe', lines: [h('Tuesday lunch'), p('I used 2 cups of leftover rice, but the original calls for 3.'), p('No ingredient list was provided.'), q('> Cook until tender.'), p('The temperature is not specified.')] },
  { id: 'test-recipe-05', domain: 'recipe', lines: [h('SAUCE / serves 2'), h('Ingredients (metric)'), t('Ingredient\tAmount'), t('Tahini\t45 g'), t('Water\t2 tbsp'), t('Lemon juice\t15 ml'), h('Instructions'), p('Stir until smooth. Add the water gradually.')] },
  { id: 'test-recipe-06', domain: 'recipe', lines: [h('Crêpes'), l('125 g farine'), l('2 œufs'), l('250 ml lait'), p('Mélanger. Laisser reposer 30 minutes.'), h('Notes personnelles'), p('Ne pas doubler le sel.')] },
  { id: 'test-mail-01', domain: 'email', lines: [p('From: Dana <dana@example.test>'), p('Sent: 9 September 2026 09:40'), p('Subject: Re: 2.5 kg delivery'), blank(), p('Hi Jules,'), p('Please keep the quantity at 2.5 kg.'), q('> You asked for 25 kg. Is that right?'), p('No, the decimal point matters.'), p('Dana')] },
  { id: 'test-mail-02', domain: 'email', lines: [p('Subject: Action needed'), p('Hello,'), h('Before our call'), l('Review section 4.2'), l('Bring the signed form'), p('We will meet at 14:30, not 4:30.'), p('Thanks,'), p('Sam')] },
  { id: 'test-mail-03', domain: 'email', lines: [p('ORDER CONFIRMATION'), p('Order #3819'), p('2 x Paper notebooks — $7.50 each'), p('Total: $15.00'), p('Delivery: 10–12 September'), p('Manage order: https://example.test/orders/3819')] },
  { id: 'test-mail-04', domain: 'email', lines: [p('Re: parser bug'), p('Here is the failing snippet:'), c('    if (value === "1/2") {'), c('      return 0.5;'), c('    }'), q('> Please leave the original string alone.'), p('Agreed. We should only label its structure.')] },
  { id: 'test-mail-05', domain: 'email', lines: [p('Hi Lee,'), p('The word Ingredients appears in the paragraph below.'), p('Ingredients are not listed separately in this message.'), p('NOTES'), p('That is the exact subject line I used.'), p('Cheers')] },
  { id: 'test-mail-06', domain: 'email', lines: [p('From: riley@example.test'), h('Agenda for Thursday'), l('a) Introductions'), l('b) Budget review'), l('c) Next date'), q('On Monday, Jo wrote:'), q('We agreed to limit the meeting to 25 minutes.'), p('Riley')] },
  { id: 'test-web-01', domain: 'webpage', lines: [h('Rainwater collection'), p('Updated 2026-08-21'), h('Before you begin'), p('Check the container every 7 days.'), l('• Clean the lid'), l('• Inspect the filter'), h('Capacity'), t('Small\t80 L'), t('Large\t220 L'), p('https://example.test/rain#capacity')] },
  { id: 'test-web-02', domain: 'webpage', lines: [h('API example'), p('This command prints a message:'), c('curl -X GET https://example.test/v1/status'), c('{"status":"ok","count":12}'), h('Response fields'), t('| Field | Type |'), t('| count | integer |'), p('Do not send credentials in the URL.')] },
  { id: 'test-web-03', domain: 'webpage', lines: [h('Walk timetable'), t('Start    Finish    Distance'), t('09:15    10:45     4.2 km'), t('11:00    12:30     5 km'), p('Times may change in wet weather.'), q('“Take only photographs.”'), p('More: https://example.test/walks')] },
  { id: 'test-web-04', domain: 'webpage', lines: [p('Home / Guides / Repairs'), h('Replacing a washer'), p('Read this before removing any parts.'), h('Tools required'), l('Adjustable wrench'), l('Soft cloth'), l('Replacement washer, 12 mm'), h('Step by step'), p('Turn off the supply. Remove the cap slowly.')] },
  { id: 'test-web-05', domain: 'webpage', lines: [h('Literal syntax gallery'), c('#+end_example'), c('* TODO do not execute'), c(':PROPERTIES:'), c(':END:'), c('[[file:private.txt]]'), p('These are examples, not instructions.')] },
  { id: 'test-web-06', domain: 'webpage', lines: [h('A short interview'), q('Q: What did you measure?'), q('A: Six labels across copied text.'), p('The speaker paused.'), q('A: Formatting alone is not enough.'), h('Further reading'), p('https://example.test/interview')] },
].map(doc => ({ ...doc, split: 'test', family: doc.id }));
