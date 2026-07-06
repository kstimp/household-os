const MATRIC_Y = 2039, MATRIC_M = 8;      // matriculation: Aug 2039
const DRAW_OFF = (MATRIC_M-1)/12;         // Aug offset within the year
const ENROLL = [2039,2040,2041,2042];
const BASE_YEAR = 2024;
const R_COLLEGE = 0.04;
const PLUS_ORIG = 0.04228;

const $ = id => document.getElementById(id);
let scenario = 'A';
let baseCOA = 28808;

let reviews = [];
let plans = [];

function fmt(n){ return '$' + Math.round(n).toLocaleString('en-US'); }
function parseMoney(s){ return parseFloat(String(s).replace(/[^0-9.]/g,'')) || 0; }

function reviewParts(){
  const v = $('review').value || '2026-07';
  const [y,m] = v.split('-').map(Number);
  return { y, m, start: y + (m-1)/12 };
}
function monthsRemaining(y,m){ return Math.max((MATRIC_Y-y)*12 + (MATRIC_M-m), 1); }
function ymToT(s){ const [y,m]=s.split('-').map(Number); return y + (m-1)/12; }

function costs(infl){ return ENROLL.map(y => baseCOA * Math.pow(1+infl, y-BASE_YEAR)); }
function monthlyRate(m, rs, re, N){        // linear glide across the remaining window
  const f = N>1 ? m/(N-1) : 0;
  return Math.pow(1 + rs + (re-rs)*f, 1/12);
}

// simulate from a review date over N remaining months, then 4 college draws
/**
 * Simulates the 529 balance from review date to graduation.
 *
 * Runs monthly projections for the pre-college saving period and the in-college
 * drawdown period, taking into account monthly contributions, glided rate of
 * return, annual college cost drawdowns, and optional cash flow support.
 *
 * Args:
 *   bal: The current starting 529 balance.
 *   monthly: The solved monthly contribution amount.
 *   infl: The annual inflation rate for college costs.
 *   rs: The starting rate of return at review date.
 *   re: The ending rate of return at enrollment.
 *   inCollege: The monthly cash flow contributed during college.
 *   loanPerYear: The annual Parent PLUS loan amount borrowed.
 *   N: Number of months remaining until matriculation.
 *   start: Decimal starting year representation of the review date.
 *
 * Returns:
 *   An object containing leftover balance, the simulation series array, the
 *   matriculation balance, total user contributions, and total withdrawals.
 */
function simulate(bal, monthly, infl, rs, re, inCollege, loanPerYear, N, start){
  loanPerYear = loanPerYear || 0;
  let b = bal, contributed = 0, withdrawn = 0;
  const series = [{t:start, bal:b, type:'current'}];
  for(let m=0; m<N; m++){
    b += monthly; contributed += monthly;
    b *= monthlyRate(m, rs, re, N);
    series.push({t:start+(m+1)/12, bal:b, type:'plan'});
  }
  const matric = b;
  const yc = costs(infl);
  const mrC = Math.pow(1+R_COLLEGE, 1/12);
  ENROLL.forEach((yr,i) => {
    const t0 = yr + DRAW_OFF;
    const draw = Math.max(yc[i] - loanPerYear, 0);   // loans cover part of the bill
    b -= draw; withdrawn += draw;
    series.push({t:t0, bal:b, type:'drawdown'});
    for(let k=0;k<12;k++){
      b += inCollege; contributed += inCollege; b *= mrC;
      series.push({t:t0+(k+1)/12, bal:b, type:'drawdown'});
    }
  });
  return {leftover:b, series, matric, contributed, withdrawn};
}

function solveMonthly(bal, infl, rs, re, inCollege, loanPerYear, N, start){
  const f0 = simulate(bal,0,infl,rs,re,inCollege,loanPerYear,N,start).leftover;
  const f1 = simulate(bal,1,infl,rs,re,inCollege,loanPerYear,N,start).leftover;
  return Math.max(-f0/(f1-f0), 0);
}

function loanCost(netTotal, rate){
  if(netTotal<=0) return {gross:0, atGrad:0, monthly:0, interest:0};
  const gross = netTotal/(1-PLUS_ORIG), perYear = gross/4;
  let atGrad = 0;
  [4.5,3.5,2.5,1.5].forEach(t => atGrad += perYear*Math.pow(1+rate,t));
  const mr = rate/12, n = 120;
  const pmt = atGrad*mr/(1-Math.pow(1+mr,-n));
  return {gross, atGrad, monthly:pmt, interest:pmt*n - gross};
}

/**
 * Draws the projected 529 balance chart onto the SVG canvas.
 *
 * Args:
 *   series: Array of projected balance data points.
 *   history: Array of historical review data points.
 *   curT: Decimal year of the current review.
 *   curBal: Current balance amount.
 */
function drawChart(series, history, curT, curBal){
  const svg = $('chart');
  const W=640,H=240,padL=52,padR=12,padT=14,padB=26;
  const allPts = series.concat(history, [{t:curT,bal:curBal,type:'current'}]);
  const xs = allPts.map(p=>p.t), ys = allPts.map(p=>p.bal);
  const xMin = Math.min(...xs), xMax = Math.max(...series.map(p=>p.t));
  const yMax = Math.max(...ys)*1.08, yMin = Math.min(0,...ys);
  const X = t => padL + ((t-xMin)/(xMax-xMin))*(W-padL-padR);
  const Y = v => padT + (1-(v-yMin)/(yMax-yMin))*(H-padT-padB);
  const matricT = MATRIC_Y + DRAW_OFF;
  const accum = series.filter(p=>p.t<=matricT);
  const draw  = series.filter(p=>p.t>=matricT);
  const path = pts => pts.map((p,i)=>(i?'L':'M')+X(p.t).toFixed(1)+' '+Y(p.bal).toFixed(1)).join(' ');

  let g='';
  for(let i=0;i<=4;i++){
    const v = yMin + (yMax-yMin)*i/4, y=Y(v);
    g += `<line x1="${padL}" y1="${y}" x2="${W-padR}" y2="${y}" stroke="#233242" stroke-width="1"/>`;
    g += `<text x="${padL-8}" y="${y+4}" text-anchor="end" fill="#5f7286" font-size="10" font-family="IBM Plex Mono">${'$'+Math.round(v/1000)+'k'}</text>`;
  }
  const cand = [Math.ceil(xMin), 2030, 2034, 2039, 2043];
  [...new Set(cand)].filter(yr=>yr>=xMin-0.01 && yr<=xMax+0.01).forEach(yr=>{
    g += `<text x="${X(yr)}" y="${H-8}" text-anchor="middle" fill="#5f7286" font-size="10" font-family="IBM Plex Mono">${yr}</text>`;
  });
  const zeroY = Y(0);

  // past-actual line: saved reviews up to now, anchored to the current point
  const pastLine = history.filter(p=>p.t <= curT+1e-6).map(p=>({t:p.t,bal:p.bal}));
  if(!pastLine.some(p=>Math.abs(p.t-curT)<1e-6)) pastLine.push({t:curT,bal:curBal});
  pastLine.sort((a,b)=>a.t-b.t);

  let lines = '';
  if(pastLine.length>=2) lines += `<path d="${path(pastLine)}" fill="none" stroke="#2e8b83" stroke-width="2.5"/>`;
  lines += `<path d="${path(accum)}" fill="none" stroke="#49d2c2" stroke-width="2.5"/>`;
  lines += `<path d="${path(draw)}"  fill="none" stroke="#e8b04b" stroke-width="2.5"/>`;

  let dots = '';
  history.forEach(p=>{ dots += `<circle cx="${X(p.t)}" cy="${Y(p.bal)}" r="4" fill="#2e8b83" stroke="#0e1620" stroke-width="1.5"/>`; });
  dots += `<circle cx="${X(curT)}" cy="${Y(curBal)}" r="4.5" fill="#fff" stroke="#0e1620" stroke-width="1.5"/>`;

  // Create placeholder guide elements for mouse hover
  const hoverElements = `
    <line id="chart-hover-line" x1="0" y1="${padT}" x2="0" y2="${H-padB}" stroke="var(--muted)" stroke-width="1.5" stroke-dasharray="3,3" style="opacity:0; pointer-events:none;"></line>
    <circle id="chart-hover-dot" cx="0" cy="0" r="6" fill="var(--teal)" stroke="#fff" stroke-width="2" style="opacity:0; pointer-events:none;"></circle>
  `;

  svg.innerHTML = g
    + `<line x1="${padL}" y1="${zeroY}" x2="${W-padR}" y2="${zeroY}" stroke="#3a4d61" stroke-width="1"/>`
    + lines + dots + hoverElements;

  // Stash data for the event listeners
  window._lastSeries = series;
  window._lastHistory = history;
  window._lastCurT = curT;
  window._lastCurBal = curBal;
}

/**
 * Formats a decimal year representation to a "Month Year" string.
 *
 * Args:
 *   t: The decimal year value.
 *
 * Returns:
 *   Formatted string like "Jul 2026".
 */
function formatDecimalYear(t) {
  const monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const y = Math.floor(t);
  const m = Math.round((t - y) * 12) + 1;
  const adjustedY = m > 12 ? y + 1 : y;
  const adjustedM = m > 12 ? 1 : m;
  return monthNames[adjustedM - 1] + " " + adjustedY;
}

/**
 * Sets up mouse hover event listeners on the projected 529 balance chart.
 */
function setupChartHover() {
  const svg = $('chart');
  const tooltip = $('chart-tooltip');
  const TYPE_LABELS = {
    history: 'Actual Review',
    current: 'Current State',
    plan: 'Projected (Saving)',
    drawdown: 'Projected (College)'
  };
  
  svg.addEventListener('mousemove', (e) => {
    if (!window._lastSeries) return;
    
    const rect = svg.getBoundingClientRect();
    const mouseX = ((e.clientX - rect.left) / rect.width) * 640;
    
    const padL = 52, padR = 12, padT = 14, padB = 26;
    const series = window._lastSeries;
    const history = window._lastHistory || [];
    const curT = window._lastCurT;
    const curBal = window._lastCurBal;
    
    const allPts = series.concat(history, [{ t: curT, bal: curBal, type: 'current' }]);
    const xs = allPts.map(p => p.t);
    const xMin = Math.min(...xs);
    const xMax = Math.max(...series.map(p => p.t));
    
    const t = xMin + ((mouseX - padL) / (640 - padL - padR)) * (xMax - xMin);
    
    let closestPt = null;
    let minDiff = Infinity;
    allPts.forEach(p => {
      const diff = Math.abs(p.t - t);
      if (diff < minDiff) {
        minDiff = diff;
        closestPt = p;
      }
    });
    
    const hoverLine = $('chart-hover-line');
    const hoverDot = $('chart-hover-dot');
    
    if (closestPt && mouseX >= padL && mouseX <= 640 - padR) {
      const X = val => padL + ((val - xMin) / (xMax - xMin)) * (640 - padL - padR);
      const Y = val => {
        const ys = allPts.map(p => p.bal);
        const yMax = Math.max(...ys) * 1.08;
        const yMin = Math.min(0, ...ys);
        return padT + (1 - (val - yMin) / (yMax - yMin)) * (240 - padT - padB);
      };
      
      const cx = X(closestPt.t);
      const cy = Y(closestPt.bal);
      
      if (hoverLine) {
        hoverLine.setAttribute('x1', cx);
        hoverLine.setAttribute('x2', cx);
        hoverLine.style.opacity = 1;
      }
      
      if (hoverDot) {
        let dotColor = 'var(--teal)';
        if (closestPt.type === 'history') {
          dotColor = '#2e8b83';
        } else if (closestPt.type === 'drawdown') {
          dotColor = 'var(--gold)';
        } else if (closestPt.type === 'current') {
          dotColor = '#fff';
        }
        hoverDot.setAttribute('cx', cx);
        hoverDot.setAttribute('cy', cy);
        hoverDot.setAttribute('fill', dotColor);
        hoverDot.style.opacity = 1;
      }
      
      const dateStr = formatDecimalYear(closestPt.t);
      const balStr = fmt(closestPt.bal);
      const labelStr = TYPE_LABELS[closestPt.type] || '';
      
      tooltip.innerHTML = `
        <div class="tooltip-date">${dateStr}</div>
        <div class="tooltip-val">${balStr}</div>
        <div class="tooltip-label">${labelStr}</div>
      `;
      tooltip.style.display = 'block';
      
      const svgRect = svg.getBoundingClientRect();
      const parentRect = svg.parentElement.getBoundingClientRect();
      
      const tooltipX = (cx / 640) * svgRect.width;
      const tooltipY = (cy / 240) * svgRect.height;
      
      tooltip.style.left = `${tooltipX}px`;
      tooltip.style.top = `${tooltipY - 8}px`;
      tooltip.style.transform = 'translate(-50%, -100%)';
    } else {
      hideTooltip();
    }
  });
  
  svg.addEventListener('mouseleave', hideTooltip);
  
  function hideTooltip() {
    const hoverLine = $('chart-hover-line');
    const hoverDot = $('chart-hover-dot');
    if (hoverLine) hoverLine.style.opacity = 0;
    if (hoverDot) hoverDot.style.opacity = 0;
    tooltip.style.display = 'none';
  }
}

/**
 * Calculates yearly target balances and renders the targets table.
 *
 * Args:
 *   series: The simulated timeline data series.
 *   start: The decimal year of the review start.
 */
function renderYearlyTargets(series, start) {
  const startYear = Math.floor(start);
  const endYear = 2043;
  const tbody = $('targetsTableBody');
  let rowsHtml = '';
  
  for (let yr = startYear; yr < endYear; yr++) {
    const targetT = yr + 11/12;
    let closestPt = null;
    let minDiff = Infinity;
    
    series.forEach(p => {
      const diff = Math.abs(p.t - targetT);
      if (diff < minDiff) {
        minDiff = diff;
        closestPt = p;
      }
    });
    
    if (closestPt && minDiff < 0.05) {
      const isCollege = yr >= MATRIC_Y;
      const badgeClass = isCollege ? 'in-college' : 'pre-college';
      const badgeText = isCollege ? 'College Drawdown' : 'Accumulation';
      
      rowsHtml += `
        <tr>
          <td>December ${yr}</td>
          <td><span class="status-badge ${badgeClass}">${badgeText}</span></td>
          <td class="num">${fmt(closestPt.bal)}</td>
        </tr>
      `;
    }
  }
  
  if (series.length > 0) {
    rowsHtml += `
      <tr>
        <td>Graduation (Aug 2043)</td>
        <td><span class="status-badge graduation">Graduation</span></td>
        <td class="num">${fmt(series[series.length - 1].bal)}</td>
      </tr>
    `;
  }
  
  tbody.innerHTML = rowsHtml;
}

/**
 * Sets up event listeners for opening, closing, and dismissing the yearly targets modal.
 */
function setupTargetsModal() {
  const modal = $('targetsModal');
  const openBtn = $('viewTargetsBtn');
  const closeBtn = $('closeTargetsBtn');
  
  openBtn.onclick = () => {
    modal.style.display = 'flex';
    modal.offsetHeight; // force reflow
    modal.classList.add('show');
  };
  
  const hideModal = () => {
    modal.classList.remove('show');
    setTimeout(() => {
      if (!modal.classList.contains('show')) {
        modal.style.display = 'none';
      }
    }, 200);
  };
  
  closeBtn.onclick = hideModal;
  
  modal.onclick = (e) => {
    if (e.target === modal) {
      hideModal();
    }
  };
}

function render(){
  const {y, m, start} = reviewParts();
  const N = monthsRemaining(y, m);
  $('monthsRem').textContent = N;
  $('reviewNote').textContent = N + ' months left';

  const bal = parseMoney($('balance').value);
  const infl = parseFloat($('infl').value)/100;
  const rs = parseFloat($('retStart').value)/100;
  const re = parseFloat($('retEnd').value)/100;
  const cash = parseFloat($('cash').value);
  const loanTot = parseFloat($('loan').value);
  const loanRate = parseFloat($('loanRate').value)/100;

  let sumPV = 0;
  for (let m = 1; m <= 48; m++) {
    sumPV += cash / Math.pow(1 + infl, (N + m) / 12);
  }
  const npvMonthly = cash > 0 ? sumPV / 48 : 0;

  $('inflVal').textContent = (infl*100).toFixed(1)+'%';
  $('retVal').textContent = (rs*100).toFixed(1)+'% \u2192 '+(re*100).toFixed(1)+'%';
  
  const npvText = cash > 0 ? ` <span style="color:var(--faint); font-weight:normal; font-size:12px; margin-left:4px;">(${fmt(npvMonthly)}/mo NPV)</span>` : '';
  $('cashVal').innerHTML = '$' + cash.toLocaleString() + '/mo' + npvText;

  $('loanVal').textContent = '$'+loanTot.toLocaleString();
  $('loanRateVal').textContent = (loanRate*100).toFixed(2)+'%';

  const inCollege = scenario==='B' ? cash : 0;
  const loanPerYear = scenario==='C' ? loanTot/4 : 0;
  const monthly = solveMonthly(bal, infl, rs, re, inCollege, loanPerYear, N, start);
  const sim = simulate(bal, monthly, infl, rs, re, inCollege, loanPerYear, N, start);

  $('monthlyOut').textContent = fmt(monthly);
  $('matricOut').textContent = fmt(sim.matric);
  $('totalContribOut').textContent = fmt(bal + sim.contributed);
  $('growthOut').textContent = fmt(sim.withdrawn + sim.leftover - bal - sim.contributed);

  $('cashLever').style.display     = scenario==='B' ? '' : 'none';
  $('loanLever').style.display     = scenario==='C' ? '' : 'none';
  $('loanRateLever').style.display = scenario==='C' ? '' : 'none';

  const loanBox = $('loanBox');
  if(scenario==='A'){
    $('scenNote').innerHTML = 'Covers all four years from the 529 alone. <b>No payments or loans during college.</b>';
    loanBox.classList.remove('show');
  } else if(scenario==='B'){
    $('scenNote').innerHTML = 'Plus <b>'+fmt(cash)+'/mo</b> <span style="color:var(--muted); font-size:13px; font-weight:normal;">('+fmt(npvMonthly)+'/mo NPV)</span> from income during college ('+fmt(cash*48)+' total over 4 yrs).';
    loanBox.classList.remove('show');
  } else {
    const lc = loanCost(loanTot, loanRate);
    $('scenNote').innerHTML = 'The 529 covers the rest; you borrow <b>'+fmt(loanTot)+'</b> and repay <b>'+fmt(lc.monthly)+'/mo</b> for 10 yrs after graduation.';
    $('loanOwed').textContent = fmt(lc.atGrad);
    $('loanPmt').textContent  = fmt(lc.monthly);
    $('loanInt').textContent  = fmt(lc.interest);
    loanBox.classList.toggle('show', loanTot>0);
  }

  const yc = costs(infl);
  let rows='';
  ENROLL.forEach((yr,i)=>{
    rows += `<div class="row"><span class="yr">${yr}\u2013${(yr+1)%100}</span><span class="amt">${fmt(yc[i])}</span></div>`;
  });
  rows += `<div class="row total"><span class="yr">4-year total</span><span class="amt">${fmt(yc.reduce((a,b)=>a+b,0))}</span></div>`;
  $('costRows').innerHTML = rows;

  const history = reviews.map(r => ({ t: ymToT(r.date), bal: r.balance, type: 'history' }));
  drawChart(sim.series, history, start, bal);
  renderYearlyTargets(sim.series, start);
  window._cur = {date:$('review').value, balance:bal, scenario, monthly:Math.round(monthly)};
}

// ---- review log (API) ----
const PLAN_LABEL = {A:'Fund upfront', B:'+ Cash flow', C:'+ Parent loans'};

async function loadAndRenderReviews() {
  try {
    const res = await fetch('/api/reviews');
    if (res.ok) {
      reviews = await res.json();
      renderLog();
    }
  } catch (e) {
    console.error('Failed to load reviews from server:', e);
  }
}

function renderLog(){
  const body = $('logBody');
  if(!reviews.length){
    body.innerHTML = '<tr><td colspan="5" class="empty">No reviews saved yet. Set the date + balance, then Save this review.</td></tr>';
    return;
  }
  body.innerHTML = reviews.map(r =>
    `<tr>
      <td>${r.date}</td>
      <td class="num">${fmt(r.balance)}</td>
      <td>${PLAN_LABEL[r.scenario]||r.scenario}</td>
      <td class="num">${fmt(r.monthly)}/mo</td>
      <td><button class="btn danger mini" onclick="deleteReview('${r.date}')">Delete</button></td>
    </tr>`
  ).join('');
}

async function saveReview() {
  const c = window._cur;
  try {
    const res = await fetch('/api/reviews', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(c)
    });
    if (res.ok) {
      await loadAndRenderReviews();
      render();
    } else {
      alert('Failed to save review');
    }
  } catch (e) {
    console.error(e);
    alert('Failed to save review');
  }
}

async function deleteReview(date) {
  if (confirm(`Delete review for ${date}?`)) {
    try {
      const res = await fetch(`/api/reviews/${date}`, { method: 'DELETE' });
      if (res.ok) {
        await loadAndRenderReviews();
        render();
      } else {
        alert('Failed to delete review');
      }
    } catch (e) {
      console.error(e);
      alert('Failed to delete review');
    }
  }
}
window.deleteReview = deleteReview; // Expose to global scope for onclick handler

// ---- plans management (API) ----
async function loadAndRenderPlans() {
  try {
    const res = await fetch('/api/plans');
    if (res.ok) {
      plans = await res.json();
      renderPlans();
    }
  } catch (e) {
    console.error('Failed to load plans from server:', e);
  }
}

function renderPlans() {
  const container = $('plansList');
  if (!plans.length) {
    container.innerHTML = '<div class="no-plans">No saved plans. Save current configuration below.</div>';
    return;
  }
  container.innerHTML = plans.map(p => {
    const residencyLabel = p.residency === 'in-state' ? 'KU In-state' : 'Out-of-state';
    const desc = `${PLAN_LABEL[p.scenario]} &middot; ${residencyLabel} &middot; ${p.infl}% infl`;
    return `
      <div class="plan-item">
        <div class="plan-info">
          <div class="plan-name">${p.name}</div>
          <div class="plan-meta">${desc}</div>
        </div>
        <div class="plan-ops">
          <button class="btn mini" onclick="loadPlan('${p.name}')">Load</button>
          <button class="btn mini-danger" onclick="deletePlan('${p.name}')">Delete</button>
        </div>
      </div>
    `;
  }).join('');
}

async function savePlan() {
  const name = $('planNameInput').value.trim();
  if (!name) {
    alert('Please enter a plan name');
    return;
  }
  
  const payload = {
    name,
    balance: parseMoney($('balance').value),
    infl: parseFloat($('infl').value),
    retStart: parseFloat($('retStart').value),
    retEnd: parseFloat($('retEnd').value),
    cash: parseFloat($('cash').value),
    loan: parseFloat($('loan').value),
    loanRate: parseFloat($('loanRate').value),
    residency: baseCOA === 28808 ? 'in-state' : 'out-of-state',
    scenario: scenario,
    reviewDate: $('review').value
  };

  try {
    const res = await fetch('/api/plans', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    if (res.ok) {
      $('planNameInput').value = '';
      await loadAndRenderPlans();
    } else {
      alert('Failed to save plan');
    }
  } catch (e) {
    console.error(e);
    alert('Failed to save plan');
  }
}

function loadPlan(name) {
  const plan = plans.find(p => p.name === name);
  if (!plan) return;

  $('balance').value = plan.balance.toLocaleString('en-US');
  $('infl').value = plan.infl;
  $('retStart').value = plan.retStart;
  $('retEnd').value = plan.retEnd;
  $('cash').value = plan.cash;
  $('loan').value = plan.loan;
  $('loanRate').value = plan.loanRate;
  $('review').value = plan.reviewDate;
  
  baseCOA = plan.residency === 'in-state' ? 28808 : 47138;
  $('resSeg').querySelectorAll('button').forEach(b => {
    b.classList.toggle('on', parseFloat(b.dataset.coa) === baseCOA);
  });

  scenario = plan.scenario;
  $('scenToggle').querySelectorAll('button').forEach(b => {
    b.classList.toggle('on', b.dataset.scen === scenario);
  });

  render();
}
window.loadPlan = loadPlan; // Expose to global scope for onclick handler

async function deletePlan(name) {
  if (confirm(`Delete plan "${name}"?`)) {
    try {
      const res = await fetch(`/api/plans/${encodeURIComponent(name)}`, { method: 'DELETE' });
      if (res.ok) {
        await loadAndRenderPlans();
      } else {
        alert('Failed to delete plan');
      }
    } catch (e) {
      console.error(e);
      alert('Failed to delete plan');
    }
  }
}
window.deletePlan = deletePlan; // Expose to global scope for onclick handler

// ---- events ----
$('scenToggle').querySelectorAll('button').forEach(b=>b.onclick=()=>{
  scenario=b.dataset.scen;
  $('scenToggle').querySelectorAll('button').forEach(x=>x.classList.toggle('on',x===b));
  render();
});
$('resSeg').querySelectorAll('button').forEach(b=>b.onclick=()=>{
  baseCOA=parseFloat(b.dataset.coa);
  $('resSeg').querySelectorAll('button').forEach(x=>x.classList.toggle('on',x===b));
  render();
});
['infl','retStart','retEnd','cash','loan','loanRate','review'].forEach(id=>$(id).addEventListener('input',render));
$('balance').addEventListener('input',render);
$('balance').addEventListener('blur',e=>{
  const v=parseMoney(e.target.value); e.target.value=v?v.toLocaleString('en-US'):'';
});

$('saveReview').onclick = saveReview;
$('savePlanBtn').onclick = savePlan;

// ---- initialize ----
async function init() {
  await Promise.all([
    loadAndRenderReviews(),
    loadAndRenderPlans()
  ]);
  setupChartHover();
  setupTargetsModal();
  render();
}

init();
