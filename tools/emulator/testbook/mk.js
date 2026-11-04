const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage();
  await p.goto('file://' + process.argv[2]);
  await p.evaluate(() => renderMathInElement(document.body, {delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}]}));
  await p.waitForTimeout(500);
  await p.pdf({ path: process.argv[3], preferCSSPageSize: true });
  await b.close();
})();
