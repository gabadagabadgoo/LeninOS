$ErrorActionPreference = 'Stop'
$logFile = Join-Path $PSScriptRoot 'build_crash.log'

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {

# ============================================================
# CLEAN
# ============================================================
if (Test-Path 'LeninOS-win32-x64\LeninOS.exe') {
    Log 'Previous build detected. Cleaning...'
    Remove-Item 'LeninOS-win32-x64' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'leninos-src' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'build' -Recurse -Force -ErrorAction SilentlyContinue
    Log 'Cleaned.'
}

# ============================================================
# NODE.JS
# ============================================================
if (-not (Test-Path 'node\node.exe')) {
    Log 'Requisitioning Node.js...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $nodeDir = Join-Path $PSScriptRoot 'node'
    $zip = Join-Path $env:TEMP 'nodejs.zip'
    $url = 'https://nodejs.org/dist/v20.11.1/node-v20.11.1-win-x64.zip'
    if (-not [Environment]::Is64BitOperatingSystem) {
        $url = 'https://nodejs.org/dist/v20.11.1/node-v20.11.1-win-x86.zip'
    }
    (New-Object Net.WebClient).DownloadFile($url, $zip)
    $ex = Join-Path $env:TEMP 'nodejs_extract'
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ex)
    $sd = Get-ChildItem $ex -Directory | Select-Object -First 1 -ExpandProperty FullName
    if (Test-Path $nodeDir) { Remove-Item $nodeDir -Recurse -Force }
    Move-Item $sd $nodeDir -Force
    if (-not (Test-Path 'node\node.exe')) {
        Log 'FATAL: Node.js download failed'
        exit 1
    }
    Log 'Node.js deployed.'
} else {
    Log 'Node.js already present.'
}

# ============================================================
# SOURCE DIRECTORY
# ============================================================
if (-not (Test-Path 'leninos-src')) { New-Item -ItemType Directory -Path 'leninos-src' | Out-Null }
Log 'Forging source code...'

# ============================================================
# main.js
# ============================================================
Log 'Writing main.js...'
$mainJs = @'
const { app, BrowserWindow, ipcMain, session } = require('electron');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const http = require('http');
const https = require('https');

let mainWindow;
let proxyPort = 0;
app.commandLine.appendSwitch('disable-features', 'RendererCodeIntegrity');
app.commandLine.appendSwitch('no-sandbox');

const BLOCKED_PATTERNS = [
  'del', 'rmdir', 'rd', 'format', 'rm ',
  'shutdown', 'regedit', 'net user', 'net stop',
  'takeown', 'icacls', 'diskpart', 'taskkill'
];

function isSafe(cmd) {
  const lower = cmd.toLowerCase();
  return !BLOCKED_PATTERNS.some(function(p) { return lower.indexOf(p) !== -1; });
}

function startProxy() {
  return new Promise(function(resolve) {
    const server = http.createServer(function(req, res) {
      const targetUrl = req.headers['x-target-url'];
      if (!targetUrl) {
        res.writeHead(200, {'Content-Type':'text/plain', 'Access-Control-Allow-Origin':'*'});
        res.end('Soviet Proxy Active');
        return;
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(200, {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': '*',
          'Access-Control-Max-Age': '86400'
        });
        res.end();
        return;
      }
      try {
        const parsed = new URL(targetUrl);
        const mod = parsed.protocol === 'https:' ? https : http;
        const opts = {
          hostname: parsed.hostname,
          port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
          path: parsed.pathname + parsed.search,
          method: req.method,
          headers: Object.assign({}, req.headers, { host: parsed.hostname }),
          rejectUnauthorized: false
        };
        delete opts.headers['x-target-url'];
        delete opts.headers['origin'];
        delete opts.headers['referer'];
        const proxyReq = mod.request(opts, function(proxyRes) {
          const h = Object.assign({}, proxyRes.headers);
          h['access-control-allow-origin'] = '*';
          delete h['x-frame-options'];
          delete h['content-security-policy'];
          delete h['content-security-policy-report-only'];
          res.writeHead(proxyRes.statusCode, h);
          proxyRes.pipe(res);
        });
        proxyReq.on('error', function(e) {
          res.writeHead(502, {'Content-Type':'text/plain','Access-Control-Allow-Origin':'*'});
          res.end('Proxy error: ' + e.message);
        });
        req.pipe(proxyReq);
      } catch(e) {
        res.writeHead(400, {'Content-Type':'text/plain','Access-Control-Allow-Origin':'*'});
        res.end('Bad request: ' + e.message);
      }
    });
    server.listen(0, '127.0.0.1', function() {
      proxyPort = server.address().port;
      console.log('Soviet Proxy running on port ' + proxyPort);
      resolve(proxyPort);
    });
  });
}

app.whenReady().then(async function() {
  await startProxy();

  session.defaultSession.webRequest.onHeadersReceived(function(details, callback) {
    const headers = Object.assign({}, details.responseHeaders);
    delete headers['x-frame-options'];
    delete headers['X-Frame-Options'];
    delete headers['content-security-policy'];
    delete headers['Content-Security-Policy'];
    delete headers['content-security-policy-report-only'];
    delete headers['Content-Security-Policy-Report-Only'];
    callback({ responseHeaders: headers });
  });

  mainWindow = new BrowserWindow({
    fullscreen: true,
    frame: false,
    backgroundColor: '#2b0000',
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      webviewTag: true
    }
  });
  mainWindow.loadFile('index.html');
});

app.on('window-all-closed', function() { app.quit(); });
ipcMain.handle('quit-app', function() { app.quit(); });
ipcMain.handle('get-proxy-port', function() { return proxyPort; });

ipcMain.handle('exec-command', function(e, cmd) {
  if (!isSafe(cmd)) {
    return { stdout: '', stderr: 'BLOCKED - Soviet security forbids this command.' };
  }
  return new Promise(function(r) {
    exec(cmd, { cwd: os.homedir(), timeout: 10000 }, function(err, out, serr) {
      r({ stdout: out || '', stderr: serr || '' });
    });
  });
});

ipcMain.handle('get-sysinfo', function() {
  return {
    user: os.userInfo().username,
    host: os.hostname(),
    os: os.release(),
    mem: Math.round(os.totalmem()/1024/1024),
    freemem: Math.round(os.freemem()/1024/1024),
    cpus: os.cpus().length,
    arch: os.arch(),
    uptime: Math.round(os.uptime())
  };
});

ipcMain.handle('read-dir', function(e, p) {
  try {
    return fs.readdirSync(p, {withFileTypes:true}).map(function(d) {
      return {name: d.name, isDir: d.isDirectory()};
    });
  } catch(e) {
    return {error: e.message};
  }
});
ipcMain.handle('get-homedir', function() { return os.homedir(); });
'@
[IO.File]::WriteAllText('leninos-src\main.js', $mainJs, [Text.Encoding]::UTF8)
Log 'main.js written.'

# ============================================================
# package.json
# ============================================================
Log 'Writing package.json...'
$pkg = '{ "name": "LeninOS", "version": "3.2.0", "main": "main.js", "description": "Soviet OS", "author": "The Party" }'
[IO.File]::WriteAllText('leninos-src\package.json', $pkg, [Text.Encoding]::UTF8)
Log 'package.json written.'

# ============================================================
# index.html
# ============================================================
Log 'Writing index.html...'

$gamesList = @(
'cl1','cl10bullets','cl10minutestildawn','cl12minibattles','cl1on1soccer','cl1v1lol','cl1v1tennis','cl2048','cl2048cupcakes','cl2doom',
'cl2Dshooting','cl3dash','cl3pandas','cl3pandasbrazil','cl3pandasfantasy','cl3pandasjapan','cl3pandasnight','cl3slices2','cl40xescape','cl4thandgoal',
'cl500calibercontractz','cl60secondsburgerrun','cl60secondssantarun','cl8ballclassic','cl8ballpool','cl9007199254740992','cl99balls','cl99nightsitf',
'clabandoned3','clabsolutemadness','clacecombat2','clacecombat3','clacegangstertaxi','clachievementunlocked','clachievmentunlocked','clachievmentunlocked2','clachievmentunlocked3','clachillies','clachillies2','clADarkRoom','cladayintheoffice','clADOFAI',
'cladvancewars','cladvancewars2','cladventneon','clAdventureCapatalist','cladventurecapitalist','clagariolite','clageofwar','clageofwar2','clagesofconflict','clahoysurvival','clai','clakoopasrevenge','clakoopasrevenge2','clakumanorgaiden',
'clalienhominid','clalienhominidgba','clalienskyinvasion','clalientransporter','clalienvspredator','clallbossesin1','clallocation','clamaze','clamidstthesky','clamigopancho','clamigopancho2','clamigopancho3','clamigopancho4','clamigopancho5',
'clamigopancho6','clamigopancho7','clamongus','clamorphous','clancientsins','clangry-birdsspace','clangrybirds-space','clangrybirds','clangrybirdsshowdown','clangrybirdsspace','clanimalcrossingwildworld','clanotherworld','clapotris','clappleshooter',
'clappleworm','claquaparkio','clarceuslegend','clarcheryworldtour','clarena','clarmormayhem2','clarsonate','clascent','clasmallworldcup','classesmentexaminationque','clasteroids','clasteroidsALT','clattackhole','clavalanche',
'claviamasters','claviamastersbuggy','clAwesomePirates','clawesomeplanes','clawesometanks','clawesometanks2','clB3313','clbabeltower','clbabychiccoadventure','clbabykaizo','clbabysniperinvietnam','clbackrooms','clbackrooms2D','clbackyardbaseball',
'clbackyardbaseball09','clbackyardbaseball10','clbackyardsoccer','clbaconmaydie','clbadbodyguards','clbadicecream','clbadmondaysimulator','clbadparenting','clbadpiggies','clbadtimesim','clbadtimesimulator','clbaldidecomp','clbaldisbasics','clbaldisbasicsremaster',
'clbaldisfunnewschoolultimate','clballblast','clballsandbricks','clballsandbricksgood','clbananasimulator','clbanditgunslingers','clbanjokazooie','clbanjotooie','clbankbreakout2','clbankrobbery2','clbarryhasasecret','clbas','clbaseballbros','clbasketballfrvr',
'clbasketballlegends','clbasketballstars','clbasketbattle','clbasketbros','clbasketrandom','clbasketrandomgood','clbasketslamdunk2','clbatterup','clbattlekarts','clbattles','clbattlesim','clbattlezone','clbazookaboy','clbballlegend',
'clbeachboxingsim','clbeamrider','clbearbarians','clbearsus','clben10alienforce','clben10omniverse','clben10protector','clben10racing','clben10ultimatealien','clbergentruck201x','clbfdia5b','clbigicetowertinysquare','clbigneontowertinysquare','clbigshotboxing2',
'clbigtowertinysquare','clbigtowertinysquare2','clBig_Time_Butter_Baron','clbindingofisaccsheeptime','clbioevil4','clbitlife','clbitlifeencrypted','clbitplanes','clblackjack','clblackjackbattle','clblackjackhhhh','clblacksmithlab','clblastronaut','clblazedrifter',
'clbleachvsnaruto','clblightborne','clblobsstory2','clblockblast','clblockcraftparkour','clblockcraftshooter','clblockpost','clblockthepig','clblockydemolitionderby','clblockysnakes','clbloodmoney','clbloodtournament','clbloons','clbloons2',
'clbloonspp1','clbloonspp2','clbloonspp3','clbloonspp4','clbloonspp5','clbloonsTD1','clbloonsTD2','clbloonsTD3','clbloonsTD4','clbloonsTD5','clbloonsTD6scratch','clbloxorz','clblumgiracers','clBMX2',
'clbntts','clbobtherobber','clbobtherobber2','clbobtherobber5','clbollybeat','clbomberman','clbomberman2','clbombermanhero','clboomslingers','clbottlecracks','clbottleflip3d','clbounceback','clbouncemasters','clbouncymotors',
'clBountyOfOne','clbowlalt','clboxhead2playrooms','clboxheadnightmare','clboxinglive-2','clboxinglive2','clboxingrandom','clbrainrot','clbridgerace','clBTD1','clbtd5','clbtts','clbtts2','clbubbleshooter',
'clbubbleshooterpirate','clbubbletanks','clbubbletanks2','clbubbletanks3','clbubbletanksarenas','clbubbletankstd','clbubsy','clbuckshotroulette','clbuildnowgg','clbunnyland','clburgerandfrights','clburritobison','clburritobison2','clburritobisonlaunchalibre',
'clburritobisonrevenge','clbushidoblade','clcactusmccoy','clcactusmccoy2','clcannonballs3d','clcannonfodder','clcapybaraclicker','clcarcrash3','clcardrawing','clcareatscar2deluxe','clcarkingarena','clcarmods','clcarstuntsdriving','clcastlebloodline',
'clcastlecircleofmoon','clcastlevania','clcastlevania2','clcastlevania3','clcastlevaniaariaofsorrow','clcastlevaniadawnofsorrow','clcastlevanianes','clcastlewarsmodern','clcatmario','clcatmariogood','clcatslovecake2','clcavestory','clceleste','clceleste2',
'clcellardoor','clchaosfaction2','clcheckers','clcheesechompers3d','clcheshireinachatroom','clchess','clchessclassic','clchibiknight','clchickenscream','clchickenwar','clchipschallenge','clchoppyorc','clchronotrigger','clchuzzle',
'clCircloO2','clciviballs','clciviballs2','clclashofvikings','clclassof09','clcleanupio','clclearvision','clclearvision2','clclearvision3','clclearvision4','clclearvision5','clclmadnessambulation','clclubbytheseal','clclusterrush',
'clcoalllcdemo','clcod4','clcodblackopp','clcoddefiance','clcodenamegordon','clcodmodernwarfare','clcodworldatwar','clcoffeemaker','clcolorburst3d','clcolormatch','clcolorwatersort3d','clcombopool','clcommanderkeen4','clcommanderkeen5',
'clcommanderkeen6','clconkersbadfurday','clcontra','clcontra3','clcookie-clicker','clcookieclicker','clcookieclickercool','clcookieclickergood','clcookingmama','clcookingmama2','clcookingmama3','clcoreball','clcotlk','clcountmastersstickmangames',
'clcoverorange','clcoverorange2','clcoverorangejourneygangsters','clcoverorangejourneyknights','clcoverorangejourneypirates','clcoverorangejourneyspace','clcoverorangeplayerspack','clcoverorangeplayerspack2','clcoverorangeplayerspack3','clcrankit!','clcrashbandicoot','clcrashbandicoot2','clcrashteamracing','clcrazycars',
'clcrazycattle3d','clcrazychicken3D','clcrazyfrogracer','clcrazymotorcycle','clcreeperworld2','clcrossyroad','clcrunchball3000','clcs1.6','clcsds','clcsgoclicker','clctgpnitro','clcurveball','clcuttherope','clcuttheropetimetravel',
'clcyberbungracing','clcybersensation','cldadgame','cldadnme','cldaggerfall','cldanktomb','cldborigins','cldborigins2','cldbsniper','cldbzattacksaiyans','cldbzdevolution','cldbzsuperwarriorssonic','cldeadestate','clddeadlydescent',
'cldeadplate','cldeadzed','cldeadzed2','cldeathchase','cldeblob2','cldecision','cldecision2','cldecision3','cldecisionmedieval','cldeepersleep','cldeepestsword','cldeepsleep','cldefendyourcastle','cldefendyournuts',
'cldefendyournuts2','cldeltarune','cldeltatraveler','cldementium','cldemolitionderbycrashracing','cldiablo','cldiamondhollow','cldiamondhollow2','cldiddykong-racing','clddieinthedungeon','cldigdeep','cldigdug','cldigdug2','cldigdug26',
'cldigtochina','cldinodudes','cldiredecks','cldoblox','cldogeminer','cldogeminer2','cldokidokiliteratureclub','cldonkeykong','cldonkeykong64','cldonkeykongcountry','cldonkeykongcountry2','cldonkeykongcountry3','cldonkeykongnes','cldontescape',
'cldontescape2','cldontescape3','cldoodlejump','cldoodlejumpgoober','cldoom','cldoom2','cldoom2d','cldoom2dDOS','cldoom3pack','cldoom64','cldoomdos','cldoomemscripten','cldoomps','cldoompsalt',
'cldoomzio','cldouchebaglife','cldouchebagworkout','cldownthemountain','cldragonballadvance','clDragonBallZTheLegacyofGoku','clDragonQuestIX','cldrawclimber','cldrawtheline','cldreader','cldreadheadparkour','cldriftboss','cldrifthuntersmerge','cldrivemady',
'cldrivenwild','cldrmario','cldrweedgaster','cldubstep','clduckhunt','clducklfe5','clducklife','clducklife2','clducklife3','clducklife4','clducklifebattle','clducklifespace','clducklingsio','clducktales',
'cldud','cldukenukem3d','cldumpling','cldungeondeck','cldungeonraid','cldungeonsanddegenerategamblers','cldunkshot','clduskchild','cldyingdreams','cldynamiteheaddy','cleagleride','clearntodie','clearntodie2','clearthbound',
'clearthbound3','clearthboundsnes','clearthtaken','clearthtaken2','clearthtaken3','clearthwormjim','clearthwormjim2','cledelweiss','cledyscarsimulator','cleffinghail','cleffingmachines','cleffingworms','cleffingzombies','clegg',
'cleggycar','clelasticface','clelectricman2','clemujs','clenchain','clendlesswar4','clendlesswar5','clendlesswar5wow','clendlesswar7','clenduro','clepicbattlefantasy5','clescalatingduel','clescaperoad-2','clescaperoad',
'clet','cletrianoddyssey','clevolution','clexcitebike64','clextremerun3d','clfactoryballs','clfactoryballs2','clfactoryballs3','clfactoryballs4','clfashionbattle','clfattygenius','clfearstofathomhomealone','clfeedus','clfeedus2',
'clfeedus3','clfeedus4','clfeedus5','clFF3','clff6','clffmysticquest','clFFsonic1','clFFsonic2','clFFsonic3','clFFsonic4','clFFsonic5','clFFsonic61','clFFsonic62','clFIFA07',
'clFIFA10','clFIFA11','clFIFA2000(1)','clfifa2000','clFIFA99','clFIFAinternationalsoccer','clFIFAroadtoworldcup98','clFIFAsoccer06','clFIFAsoccer95','clFIFAsoccer96','clFIFAsoccer97','clFIFAstreet2','clfinalearth2','clfinalfantasy',
'clfinalfantasyII','clfinalfantasytactics','clfinalfantasyVI','clfinalfantasyVII','clfinalfantasyVIId2','clfinalfantasyVIId3','clfinalfantasyVIItheothertetrr','clfinalninja','clfireblob','clfireboyandwatergirl','clfireboyandwatergirl2','clfireboyandwatergirl3','clfireboyandwatergirl5','clfireboyandwatergirl6',
'clfireemblem','clfisheatgettingbig','clfisquarium','clfivenightsatbaldisredone','clfivenightsatshrekshotel','clflashsonic','clfloodrunner','clfloodrunner2','clfloodrunner4','clfluidism','clfnac1','clfnac2','clFNAF','clFNAF2',
'clFNAF3','clFNAF4','clfnaf4halloween','clfnafanimatronics','clfnafps','clfnafsl','clfnafucn','clfnafworldd','clfnfagoti','clfnfblackbetrayal','clfnfbside','clfnfcamelliarudeblaster','clfnfcrunchin','clfnfdesolation',
'clfnfdokitakeoverplus','clfnfdropandroll','clfnfdustin','clfnffleetway','clfnffnaf3','clfnfgamebreakerbundle','clfnfgoldenapple','clfnfhex','clfnfholiday','clfnfhorkglorpgloop','clfnfhypnoslullaby','clfnfimposterv4','clfnfindiecross','clfnfmadnesspoop',
'clfnfmariomadnessdside','clfnfmidfight','clfnfmiku','clfnfmobmod','clfnfneo','clfnfpiggyfield','clfnfpokepastaperdition','clfnfqt','clfnfrevmixed','clfnfrewrite','clfnfselfpaced','clfnfshaggy4keys','clfnfshaggyxmatt','clfnfshucks-v2',
'clfnfshucksv2','clfnfsky','clfnfsoft','clfnfsonicexe','clfnfsonicexe4','clfnftailsgetstrolled','clfnftricky','clfnfwednesday-infedility','clfnfwhitty','clfnfzardy','clfocus','clfolder_dungeon','clfootball_bros','clfootball_legends',
'clfork_n_sausage','clfort_zone','clfpa4p1','clfpa4p2','clfreegemas','clfreerider','clfreerider2','clfreerider3','clfriday_night_funkin','clfrom_rust_to_ash','clfruit_ninja','clfunny_battle','clfunny_battle_2','clfunny_mad_racing',
'clfunny_shooter_2','clfunny_shooter_2_2','clfzero','clfzerox','clgalaga','clgame_and_watch_collection','clgangsta_bean','clgangsta_bean_2','clgangster_bros','clgarcello','clgdlite','clgdsubzero','clgeneral_chaos','clgeneric_fighter_maybe',
'clgeometry_dash_scratch','clgeometry_vibes','clgeorge_and_the_printer','clgetaway_shootout','clget_on_top','clGettothetop although there is no top','clget_yoked','clghost_trick','clgimme_the_airpod','clgladdi_hoppers','clglory_hunters','clglover','clgoal_south_africa','clgobble',
'clgoing_balls','clgold_digger_frvr','clgoldeneye_007','clgolden_sun','clgolden_sun_nds','clGoldenSunTheLostAge','clgold_miner','clgolf_orbit','clgolf_sunday','clgood_big_tower_tiny_square','clgood_big_tower_tiny_square_2','clgood_boy_galaxy','clgood_monkey_mart','clgoogle_baseball',
'clgoogle_dino','clgorescript_classic','clgrand_action_simulator-ny','clgrand_dad','clgrand_theft_auto_advance','clgranny','clgranny_2','clgranny_2_2','clgranny_3','clgranturismo','clgranturismo_2','clgrass_mowing','clgravity','clgravity_mod',
'clgrey-box-testing','clgrimace_birthday','clgrindcraft','clgrn','clgrow_a_garden','clgrow_den_io','clgrow_your_garden','clgta','clgta_2','clgta_2_2','clgta_2_alt','clgta_alt','clgta_alty','clgta_china',
'clguess_their_answer','clgun-spin','clgunblood','clgun_cho','clgun_knight','clgun_mayhem','clgun_mayhem_2','clgun_mayhem_2_goof','clgun_mayhem_redux','clgun_night','clgunsmoke','clgym_stack','clhacx','clhajime_ippo',
'clhalf_life','clhalo_combat_devolved','clhandshakes','clhands_of_war','clhandulum','clhanger_2','clhappy_room','clhappy_wheels','clhardware_tycoon','clHarolds_bad_day','clharvest_io','clharvest_moon','clharvest_moon_64','clhaunt_the_house',
'clheart_and_soul','clhei$t','clhelix_jump','clhellron','clhelp_no_brakes','clhero_3_flying_robot','clhextris','clhigh_stakes','clhighway_racer_2','clhighway_traffic_3d','clhill_climb_racing_lite','clHiNoHomo','clhipster_kickball','clhit_8ox',
'clhit_single_real','clhl2doom','clhobo','clhobo_2','clhobo_3','clhobo_4','clhobo_5','clhobo_6','clhobo_7','clhobo_vs_zombies','clhole_io','clhollow_knight','clhouse_of_hazards','clhuman_expenditure_program',
'clhungry_knight','clhungry_lamu','clhypper_sandbox','clicantbelievegoogleflaggedmeforthenameofthefilelol','clice_age_baby','clicedodo','clicy_purple_head','clidle_breakout','clidle_dice','clidle_idle_game_dev','clidle_miner_tycoon','clidle_minor_zamnshes12','climpossible_quiz','clinclement_emerald',
'clindian_truck_simiulator','clinfinite_craft','clink_game','clinnkeeper','clinside_story','clinteractive_buddy','clinto_ruins','clinto_space','clinto_space_2','clinto_space_3','clinto_the_deep_web','clintrusion','cliqball','cliron_snout',
'cliron_soldier','cliwbtg','cljacksmith','cljacksmithencryptedorsmthn','cljailbreakobbbobob','cljefflings','cljelly_dad_hero','cljelly_drift','cljelly_truck','cljelly_truck_good','cljet_force_gemini','cljetpack_joyride','cljet_rush','cljetski_racing',
'cljohnny_trigger','cljohnny_upgrade','cljourney_downhill','cljsvecx','clJUMP','cljumping_shell','cljustfalllol','cljust_hit_the_button','cljust_one_boss','clkaizo_mario_world','clkalikan','clkapi','clkarate_bros','clkarlson',
'clkart_bros','clKenGriffeyJrPresentsMajorLeagueBaseball','clkiller_instinct','clkillover','clkill_the_ice_age_baby_adventure','clkingdom_hearts_days','clkingdom_hearts_recoded','clkingdom_hearts_recoded_alt','clkirby_64','clkirby_and_the_amzing_mirror','clkirbys_adventure','clkirbys_dream_land','clkirbys_dream_land_3','clkirby_squeak_squad',
'clkirby_super_star','clkirby_super_star_ultra','clkitten_cannon','clklifur','clknife_hit','clknightmare_tower','clkonkrio','clkoopas_revenge','clkourio','cllaceys_flash_games','cllast_fire_red','cllast_horizon','cllast_stand','cllast_stand_2',
'clleader_strike','cllearn_to_fly','cllearn_to_fly_2','cllearn_to_fly_3','cllearn_to_fly_idle','cllego_batman','cllego_batman_2_super_heroes','cllego_indiana_jones','cllego_indiana_jones_2','cllego_ninjago','cllego_star_wars','cllemmings','cllevel_devil','cllever_warriors',
'cllight_it_up','cllil_runmo','clline_rider','cllink_to_the_past','cllittle_runmo','cllock_the_door','cllode_runner','cllonewolf','cllos_angeles_shark','cllow_knight','clloz1','clloz_link_awakening','clloz_minish_cap','clloz_oracle_of_seasons',
'clloz_spirit_tracks','cllucky_blocks','clmadalin_stunt_cars','clmadden_93','clmadden_94','clmadden_95','clmadden_96','clmadden_99','clmadden_football','clmadden_football_64','clmadden_nfl','clmadden_nfl_2000','clmadden_nfl_2001','clmadden_nfl_2002',
'clmaddy_98','clmadness_accelerant','clmadness_combat_defense','clmadness_combat_nexus','clmadness_gemini','clmadness_interactive','clmadness_retaliation','clmadnesss_2010','clmad_skills_motocross_2','clmad_skills_motocross_3','clmad_skills_motocross_4','clmad_skills_motocross_5','clmad_skills_motocross_lite','clmad_skills_motocross_pro',
'clmad_skills_motocross_trial','clmad_skills_motocross_world','clmad_skills_motocross_x','clmad_stick','clmad_stunt_cars_2','clmagic_tiles_3','clmajoras_mask','clmake_sure_its_closed','clmanagod','clmario_3','clmario_and_luigi_superstar_saga','clmario_combat','clmario_golf','clMarioisMissingDoneRight',
'clmario_kart_64','clmario_kart_ds','clmario_kart_super_circuit','clmario_madness','clmario_minus_rabbids','clmario_paint','clmario_party','clmario_party_2','clmario_party_3','clmario_party_ds','clmarios_mystery_meat','clmario_tennis','clmasked_forces_unlimited','clmastermind_world_conquerer',
'clmatrix_rampage','clmatt_v2','clmcfpsfbhd','clmcrae_rally','clmeat_boy','clmeat_boy_flash','clmedal_of_honor','clmedieval_shark','clmedievil','clmegachess','clmegaman','clmegaman_2','clmegaman_3','clmegaman_4',
'clmegaman_5','clmegaman_6','clmegaman_7','clmegaman_8','clmegaman_legends','clmegaman_legends_2','clmegaman_x','clmegaman_x_2','clmegaman_x_3','clmegaman_x_4','clmegaman_zero','clmegaman_zx','clmegaminer','clmelon_playground',
'clmeowuwu','clmerge_round_racers','clmetal_gear','clmetal_gear_solid','clmetal_gear_solid_ps','clmetal_slug_advance','clmetal_slug_mission_1','clmetal_slug_mission_2','clMetalSonicHyperdrive','clmetroid','clmetroid_2','clmetroid_fusion','clmetroid_zero_mission','clmiami_shark',
'clmicro_mages','clmighty_knight','clmighty_knight_2','clmimic','clmindscape','clminecraft_1-8-8','clminecraft_shooter','clmine_shooter','clminesweeper_plus','clminhero','clmini_crossword','clmini_mart','clmini_shooters','clminitooth',
'clmiragine_war','clmissle_command','clmk4ampedup','clmmwilywars','clmob_control_html5','clmobius_revolution','clmoney_rush','clmonkey_mart','clmonkey_mart_enc','clmonster_tracks','clmonster_truck_port_stunt','clmortal_kombat','clmortal_kombat_2','clmortal_kombat_3',
'clmortal_kombat_advance','clmortkom4','clmotherload','clmoto_road_rash','clmotox3m_2','clmotox3m_3','clmotox3m_m','clmotox3m_pool_party','clmotox3m_spookyland','clmotox3m_winter','clmountain_bike_racer','clmrracer','clms_pacman','clmultitask',
'clmutilate-a-doll','clmx_offroad_master','clmy_friend_pedro','clmy_friend_pedro_arena','clmy_teardrop','cln','clnarc','clnatural_selection','clNBA_hangtime','clNBA_jam','clnbajam_TE','clneon_blaster','clneon_rider','clnes_world_champion',
'clnet_attack','clneverending_legacy','clnewgrounds_rumble','clnew_super_mario_bros','clNewSuperMarioWorld2AroundtheWorld','clnew_york_shark','clnextdoor','clnfl_blitz','clnfs_carbon_own_city','clnfs_most_wanted','clnfs_porche_unleashed','clnfs_underground','clnfs_underground_2','clngon',
'clnhl_2002','clnhlhitz_2003','clnickelodeon_super_brawl_2','clNicktoonsFreezeFrameFrenzy','clnightclub_showdown','clnightfire','clnightshade','clnimrods','clninja_brawl','clnintendogs_lab','clnintendo_world_cup','clnitromemustdie','clnoob_miner','clnot_your_pawn',
'clnplus','clnubbys_number_factory','clnull_kevin','clNutsandBoltsScrewingPuzzle','clnzp','clobby-99-will-lose','clobby_only_up','clobey_the_game','clocarina_of_time','cloffline_paradise','clomega_nugget_clicker','clone_bit_adventure','clone_night_as_freddy','clone_piece',
'clone_piece_fighting','clonly_up','cloperius','clopposite_day','clopposum_country','clorb_of_creation','clordinary_sonic_romhack','cloregon_trail','closu','clourple_guy','clovo','clovo_2','clovo_dimensions','clovo_fixed',
'clpacman','clpacman_super_fast','clpapa_bakeria','clpapa_donut','clpapa_louie_night_hunt_2','clpapa_louie_when_burgers_attack','clpapa_louie_when_pizzas_attack','clpapa_louie_when_sundaes_attack','clpapa_pizza_good','clpapa_pizza_mamamia','clpapas_cheeseria','clpapas_cupcakeria','clpapas_freezeria','clpapas_hot_doggeria',
'clpapas_pancakeria','clpapas_pastaria','clpapas_scooperia','clpapas_sushiria','clpapas_tacomia','clpapas_wingeria','clpaper_io','clpaper_io_3d','clpaper_io_mania','clpaper_mario','clpaper_mario_ttyd','clparappa_the_rapper','clparking_fury','clparking_fury_2',
'clparking_fury_3','clparking_rush','clpartners_in_time','clpeacekeeper','clpeggle','clpenalty_kicks','clpenguin_diner','clpenguin_pass','clpepsiman','clpereelous','clperfect_dark','clperfect_hotel','clpersona','clphasma',
'clpheonix_justice_for_all','clpheonix_right_ace_attorny','clpheonix_trials_and_year','clpibby_apocalypse','clpico8','clpico8_edu','clpico_driller','clpico_hot','clpico_life','clpico_night_punkin','clpico_s_school','clpico_vs_beardx','clpieces_of_cake','clpikwip',
'clping_pong_chaos','clpink_bike','clpitfall','clpit_of_100_trials','clpixel_battlegrounds_io','clpixel_combat_2','clpixel_quest_lost_idols','clpixel_shooter','clpixel_speedrun','clpixel_warfare','clpizza_papa','clpizza_tower','clplangman','clplants_vs_zombies',
'clplazma_burst','clplinko','clplonky','clpogo_3D','clpoke_battle_fact','clpoke_black','clpoke_black_2','clpoke_blue','clpoke_classic','clpoke_crown','clpoke_crystal_clear','clpoke_diamond','clpoke_dream_stone','clpoke_elite_redux',
'clpoke_elysiuma','clpoke_elysiumb','clpoke_emerald_enhanced','clpoke_emerald_exceeded','clpoke_emerald_horizons','clpoke_emerald_random','clpoke_fire_gold','clpoke_flora','clpoke_gaia','clpoke_gs_chronicles','clpoke_heartgold','clpoke_light_platinum','clpoke_liquid_crysta','clpoke_mega_moemon',
'clpokemon_amnesia','clpokemon_clover','clpokemon_crystal','clpokemon_emerald','clpokemon_emerald_crest','clpokemon_emerald_imperium','clpokemon_emerald_kaizo','clpokemon_emerald_mini','clPokemonemeraldrouge','clpokemon_emerald_seaglass','clpokemon_energized_emerald','clpokemon_evolved','clpokemon_firered','clpokemon_firered_randomized',
'clpokemon_gold','clpokemon_kaizo_iron_firered','clpokemon_lazarus','clpokemon_leafgreen','clpokemon_modern_emerald','clpokemon_mystery_dungeon','clpokemon_quetzal','clpokemon_roaring_red','clPokemonrocketedition','clpokemon_ruby','clpokemon_sapphire','clpokemon_shin_sigma','clpokemon_silver','clpokemon_snap',
'clpokemon_stadium','clpokemon_tower_defense','clpokemon_ultimate_fusion','clpokemon_unbound','clpokemystery_explorers_of_sky','clpoke_odyssey','clpoke_pearl','clpoke_perfect_firered','clpoke_pisces','clpoke_platinum','clpoke_platinum_randomized','clpoke_recharged_pink','clpoke_recharged_yellow','clpoke_record_keepers',
'clpoke_red','clpoke_rocket_edition','clpoke_rowe','clpoke_ruby','clpoke_run_and_bun','clpoke_scorched_silver','clpoke_soulsilver','clpoke_the_pit','clpoke_tourmaline','clpoke_ultraviolet','clpoke_unova_emerald','clpoke_vega','clpoke_volt_white_2_redux','clpoke_voyager',
'clpoke_white','clpoke_white_2','clpoke_yellow','clPok_mon_stunning_steel','clpolice_pursuit_2','clpolished_crystal','clpoor_bunny','clpopeye_papi','clporklike','clportal','clportal_2d','clportal_defenders_fast_break','clportal_defenders_TD','clportal_flash',
'clporter','clpossess_quest','clpostal','clpotato_man_seeks_the_troof','clpou','clpraxis_fighter_x','clpre_bronze_age','clpre_civilation_bronze_age','clprehistoric_shark','clprimary','clpull_frog','clpunch_out','clpunch_the_drump','clpunch_the_trump',
'clpuppet_hockey','clpush_your_luck','clpuyo_puyo_fever','clpvz','clpvz_2','clpvz_2_gardenless','clpyro_toad','clqbert','clquake_2','clquake_3','clquake_64','clquickie_world','clqwop','clrace_master_3d',
'clracing_arena','clradical_red','clrad_racer','clraft_wars','clraft_wars_2','clragdoll-io','clragdoll_archers','clragdoll_hit','clragdoll_runners','clragdoll_soccer','clragoll_hit','clrainbow_six','clray_1','clray_2',
'clrayman','clraze','clraze_2','clraze_3','clre_3','clreach_the_core','clreal_flight_sim','clrebuild','clrebuild_2','clrecoil','clred_ball','clred_ball_2','clred_ball_3','clred_ball_4',
'clred_ball_4_vol2','clred_ball_4_vol3','clred_handed','clred_tie_runner','clred_vs_blue_2','clred_vs_blue_war','clreign_of_centipede','clrenegades','clresident_evil','clresident_evil_2','clresizer','clresort_empire','clretro_bowl','clretro_bowl_college',
'clretro_highway','clretro_ping_pong','clreturn_man','clreturn_man_2','clreturn_to_riddle_school','clrevolution_idle','clrhythm_heaven','clrhythymym_heaven','clricochet_kills_2','clriddle_middle_school','clriddle_school','clriddle_school_2','clriddle_school_3','clriddle_school_4',
'clriddle_transfer','clriddle_transfer_2','clridge_racer','clroad_fighter','clroad_of_fury','clroad_of_the_dead','clroad_of_the_dead_2','clrocket_jump','clrocket_knight_adventures','clrocket_league','clrocketpult','clrocket_soccer_derby','clrodha','clrogue_soul',
'clrogue_soul_2','clroller_baller','clrolling_sky','clrolly_vortex','clroly_poly_monster','clrooftop_snipers','clrooftop_snipers_2','clroom_clicker','clrotate','clroulette_knight','clruffle','clrun-2','clrun','clrun_2',
'clrun_3','clrussian_car_driver','clsandbox_city','clsandboxels','clsands_of_the_coliseum','clsandtris','clsantarun','clsas_zombie_assault_2','clsaul_goodman_run','clscarlet_shift','clscary_maze_game','clscrap_metal_3','clscrapyard_dog','clscribblenauts',
'clscuba_bear','clsea_mongrel','clsecret_of_mana','clsega_2_gg','clsentry_fortress','clserenitrove','clserving_up_madness','clsfk','clsfk_2','clsfk_last_stand','clsfk_league','clshaggy','clshc1','clshc2',
'clshc3','clshift','clshift_2','clshift_3','clshin_megami_tensei_devil_survivor','clshort_life','clshredmill','clshrek-2','clshrubnaut','clshw_ultimatem','clside_effects','clside_pocket','clsierra7','clsilent_hill',
'clsilk','clsiloshow'
)

$gamesJsArray = "'" + ($gamesList -join "','") + "'"

$html = @"
<!DOCTYPE html>
<html>
<head>
<style>
@font-face { font-family: 'Soviet'; src: local('Impact'); }
* { box-sizing: border-box; user-select: none; }
body { margin: 0; overflow: hidden; background: #2b0000; color: #ffd700; font-family: 'Consolas', monospace; }
#scanlines { position: fixed; inset: 0; background: linear-gradient(rgba(18,16,16,0) 50%, rgba(0,0,0,0.25) 50%), linear-gradient(90deg, rgba(255,0,0,0.06), rgba(0,255,0,0.02), rgba(0,0,255,0.06)); background-size: 100% 2px, 3px 100%; pointer-events: none; z-index: 9999; opacity: 0.4; }
#bootScreen { position: fixed; inset: 0; background: #1a0000; display: flex; flex-direction: column; justify-content: center; align-items: center; z-index: 5000; padding: 50px; }
#bootText { width: 100%; max-width: 800px; height: 300px; color: #ff3333; font-size: 14px; white-space: pre-wrap; overflow: hidden; border: 1px solid #550000; padding: 10px; background: #000; margin-bottom: 20px; }
#bootBar { width: 100%; max-width: 800px; height: 20px; border: 2px solid #ffd700; padding: 2px; }
#bootFill { height: 100%; width: 0%; background: #ff0000; }
#desktop { width: 100vw; height: 100vh; display: none; flex-direction: column; }
#bg { position: absolute; inset: 0; display: flex; justify-content: center; align-items: center; pointer-events: none; }
.emblem { width: 400px; height: 400px; opacity: 0.1; border: 20px solid #ffd700; border-radius: 50%; display: flex; justify-content: center; align-items: center; font-size: 200px; color: #ffd700; }
.watermark { position: absolute; bottom: 60px; right: 30px; font-family: 'Soviet'; font-size: 60px; opacity: 0.1; color: #ffd700; }
#winArea { flex: 1; position: relative; overflow: hidden; }
.win { position: absolute; background: #1a1a1a; border: 3px solid #ffd700; display: flex; flex-direction: column; box-shadow: 10px 10px 0 rgba(0,0,0,0.5); min-width: 200px; min-height: 100px; }
.win.underground { border-color: #00ff41; box-shadow: 0 0 20px rgba(0,255,65,0.3), 10px 10px 0 rgba(0,0,0,0.5); }
.win.underground .win-head { background: #003300; border-bottom-color: #00ff41; }
.win.underground .win-title { color: #00ff41; }
.win-head { height: 36px; min-height: 36px; background: #800000; display: flex; align-items: center; padding: 0 5px; cursor: move; border-bottom: 2px solid #ffd700; flex-shrink: 0; }
.win-title { flex: 1; font-weight: bold; padding-left: 10px; white-space: nowrap; overflow: hidden; }
.win-btn { width: 30px; height: 24px; background: #500000; border: 1px solid #ffd700; color: #ffd700; margin-left: 5px; cursor: pointer; font-size: 12px; }
.win-btn:hover { background: red; color: white; }
.win-body { flex: 1; position: relative; display: flex; flex-direction: column; background: #000; overflow: hidden; min-height: 0; }
.browser-nav { height: 40px; min-height: 40px; background: #333; display: flex; align-items: center; padding: 0 5px; gap: 5px; border-bottom: 1px solid #555; flex-shrink: 0; }
.browser-nav.underground-nav { background: #0a1a0a; border-bottom-color: #00ff41; }
.browser-webview-wrap { flex: 1; position: relative; overflow: hidden; }
.browser-webview-wrap webview { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: none; }
.underground-status { height: 24px; min-height: 24px; background: #001a00; display: flex; align-items: center; padding: 0 10px; font-size: 11px; color: #00ff41; border-top: 1px solid #003300; flex-shrink: 0; gap: 15px; }
.underground-dot { width: 8px; height: 8px; border-radius: 50%; background: #00ff41; animation: pulse 1.5s infinite; display: inline-block; }
@keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
#taskbar { height: 48px; min-height: 48px; background: #2b0000; border-top: 3px solid #ffd700; display: flex; align-items: center; padding: 0 5px; z-index: 1000; flex-shrink: 0; }
.start-btn { height: 38px; padding: 0 20px; background: #cc0000; color: #ffd700; font-weight: bold; border: 2px solid #ffd700; font-size: 16px; cursor: pointer; box-shadow: 3px 3px 0 rgba(0,0,0,0.5); }
.start-btn:active { transform: translate(2px, 2px); box-shadow: 1px 1px 0 rgba(0,0,0,0.5); }
#tasks { flex: 1; display: flex; padding: 0 10px; gap: 5px; overflow-x: auto; }
.task-btn { height: 36px; background: #400000; color: #888; border: 1px solid #600000; padding: 0 15px; cursor: pointer; font-family: 'Consolas'; white-space: nowrap; }
.task-btn.active { border-color: #ffd700; color: #ffd700; background: #600000; }
.task-btn.underground-task { border-color: #00ff41; color: #00ff41; background: #002200; }
#clock { font-weight: bold; padding: 0 15px; font-size: 16px; }
.power-btn { width: 40px; height: 38px; background: #400000; color: red; border: 1px solid red; font-size: 20px; cursor: pointer; display: flex; justify-content: center; align-items: center; }
#menu { position: absolute; bottom: 50px; left: 5px; width: 250px; background: #1a0000; border: 3px solid #ffd700; display: none; flex-direction: column; z-index: 2000; box-shadow: 10px 10px 0 #000; }
.menu-head { background: #cc0000; color: #ffd700; text-align: center; padding: 10px; font-weight: bold; font-size: 18px; border-bottom: 2px solid #ffd700; }
.menu-item { padding: 12px 20px; background: transparent; border: none; color: #ffd700; text-align: left; font-family: 'Consolas'; font-size: 14px; cursor: pointer; border-bottom: 1px solid #330000; }
.menu-item:hover { background: #ffd700; color: #000; }
.term { flex: 1; background: #000; color: #0f0; padding: 10px; overflow-y: auto; font-family: 'Consolas'; font-size: 13px; }
.term-in { background: #0a0a0a; border: none; border-top: 1px solid #333; color: #0f0; font-family: 'Consolas'; width: 100%; outline: none; padding: 8px 10px; font-size: 13px; flex-shrink: 0; }
.nav-btn { width: 30px; height: 30px; background: #444; color: #fff; border: 1px solid #666; cursor: pointer; }
.nav-btn.underground-btn { background: #003300; color: #00ff41; border-color: #00ff41; }
.nav-btn.underground-btn:hover { background: #005500; }
.url-bar { flex: 1; height: 30px; background: #000; color: #0f0; border: 1px solid #666; padding: 0 8px; font-family: 'Consolas'; font-size: 13px; }
.url-bar.underground-url { color: #00ff41; border-color: #00ff41; background: #001100; }
.gallery-view { flex: 1; display: flex; justify-content: center; align-items: center; background: #111; padding: 20px; position: relative; overflow: hidden; }
.gallery-img { max-width: 90%; max-height: 80%; border: 5px solid #ffd700; box-shadow: 0 0 30px #000; object-fit: contain; }
.gallery-cap { position: absolute; bottom: 60px; left: 50%; transform: translateX(-50%); background: rgba(0,0,0,0.8); color: #ffd700; padding: 8px 20px; border: 1px solid #ffd700; font-size: 14px; white-space: nowrap; }
.gallery-nav { height: 44px; min-height: 44px; background: #222; display: flex; justify-content: center; align-items: center; gap: 10px; border-top: 1px solid #555; flex-shrink: 0; }
.gallery-nav button { height: 32px; padding: 0 20px; background: #800000; color: #ffd700; border: 1px solid #ffd700; cursor: pointer; font-family: 'Consolas'; }
.gallery-nav button:hover { background: #cc0000; }
.gallery-counter { color: #888; font-size: 12px; }
.file-toolbar { height: 36px; min-height: 36px; background: #222; display: flex; align-items: center; padding: 0 10px; gap: 5px; border-bottom: 1px solid #555; flex-shrink: 0; }
.file-path { flex: 1; height: 26px; background: #000; color: #ffd700; border: 1px solid #555; padding: 0 8px; font-family: 'Consolas'; font-size: 12px; }
.file-list { flex: 1; overflow-y: auto; padding: 5px; }
.file-item { padding: 6px 10px; cursor: pointer; border-bottom: 1px solid #1a1a1a; font-size: 13px; display: flex; align-items: center; gap: 8px; }
.file-item:hover { background: #333; }
.file-icon { width: 16px; text-align: center; }
.file-dir { color: #ffd700; }
.file-file { color: #aaa; }
.sysinfo { flex: 1; padding: 20px; overflow-y: auto; }
.sysinfo h2 { color: #ff3333; border-bottom: 2px solid #ffd700; padding-bottom: 10px; font-family: 'Soviet'; }
.sysinfo-row { display: flex; padding: 8px 0; border-bottom: 1px solid #222; }
.sysinfo-label { width: 200px; color: #cc0000; font-weight: bold; }
.sysinfo-value { flex: 1; color: #ffd700; }
.sysinfo-bar { width: 200px; height: 16px; background: #333; border: 1px solid #555; margin-top: 2px; }
.sysinfo-fill { height: 100%; background: #cc0000; }
</style>
</head>
<body>
<div id="scanlines"></div>
<div id="bootScreen">
<div style="font-size:80px; color:#ffd700; margin-bottom:20px;">&#9773;</div>
<div id="bootText"></div>
<div id="bootBar"><div id="bootFill"></div></div>
<div style="margin-top:20px; font-weight:bold;">LENINOS v3.2 RED OCTOBER</div>
</div>
<div id="desktop">
<div id="bg"><div class="emblem">&#9773;</div><div class="watermark">LENINOS</div></div>
<div id="winArea"></div>
<div id="menu">
<div class="menu-head">&#9773; THE PARTY</div>
<button class="menu-item" onclick="launchApp('term')">&#9733; People's Terminal</button>
<button class="menu-item" onclick="launchApp('browser')">&#9733; Propaganda Net</button>
<button class="menu-item" onclick="launchApp('arcade')">&#9733; State Arcade Bureau</button>
<button class="menu-item" onclick="launchApp('gallery')">&#9733; Communist Gallery</button>
<button class="menu-item" onclick="launchApp('files')">&#9733; State Archives</button>
<button class="menu-item" onclick="launchApp('sys')">&#9733; 5-Year Plan</button>
</div>
<div id="taskbar">
<button class="start-btn" onclick="toggleMenu()">&#9733; START</button>
<div id="tasks"></div>
<div id="clock"></div>
<button class="power-btn" onclick="doShutdown()">&#x23FB;</button>
</div>
</div>
<script>
var ipcRenderer = require('electron').ipcRenderer;
var pathModule = require('path');

var bootMsgs = [
  "Initializing Marxist-Leninist Kernel v3.2...",
  "Loading dialectical materialist modules...",
  "Purging bourgeoisie data structures...",
  "Mounting /dev/proletariat...",
  "Establishing Soviet Intranet connection...",
  "Calibrating propaganda filters...",
  "Hardening security perimeter...",
  "Redistributing memory equally among processes...",
  "System ready. Glory to the Workers State!"
];

var bPhase = 0;
var bText = document.getElementById('bootText');
var bFill = document.getElementById('bootFill');
var bInt = setInterval(function() {
  if (bPhase < bootMsgs.length) {
    bText.innerText += "> " + bootMsgs[bPhase] + "\n";
    bFill.style.width = ((bPhase + 1) / bootMsgs.length * 100) + "%";
    bPhase++;
  } else {
    clearInterval(bInt);
    setTimeout(function() {
      document.getElementById('bootScreen').style.display = "none";
      document.getElementById('desktop').style.display = "flex";
    }, 800);
  }
}, 350);

setInterval(function() {
  document.getElementById('clock').innerText = new Date().toLocaleTimeString();
}, 1000);

var wins = {};
var zIdx = 10;

function createWin(title, w, h, bodyHtml, isUG) {
  var id = "w" + Date.now() + Math.random().toString(36).substr(2, 4);
  var el = document.createElement("div");
  el.className = "win" + (isUG ? " underground" : "");
  el.style.width = w + "px";
  el.style.height = h + "px";
  el.style.left = (80 + (Object.keys(wins).length * 30) % 300) + "px";
  el.style.top = (40 + (Object.keys(wins).length * 30) % 200) + "px";
  el.style.zIndex = zIdx++;
  var iconChar = isUG ? "\u2691 " : "\u2605 ";
  el.innerHTML = '<div class="win-head" data-winid="' + id + '">' +
    '<span class="win-title">' + iconChar + title + '</span>' +
    '<button class="win-btn win-max-btn" data-winid="' + id + '">[]</button>' +
    '<button class="win-btn win-close-btn" data-winid="' + id + '">X</button>' +
    '</div><div class="win-body">' + bodyHtml + '</div>';
  el.onmousedown = function() { el.style.zIndex = zIdx++; };
  document.getElementById("winArea").appendChild(el);
  wins[id] = { el: el, title: title };
  var tb = document.createElement("button");
  tb.className = "task-btn active" + (isUG ? " underground-task" : "");
  tb.innerText = title;
  tb.onclick = function() { el.style.zIndex = zIdx++; };
  tb.id = "tb" + id;
  document.getElementById("tasks").appendChild(tb);
  return id;
}

document.addEventListener("click", function(e) {
  if (e.target.classList.contains("win-close-btn")) {
    var id = e.target.getAttribute("data-winid");
    if (wins[id]) {
      wins[id].el.remove();
      var tb = document.getElementById("tb" + id);
      if (tb) tb.remove();
      delete wins[id];
    }
  }
  if (e.target.classList.contains("win-max-btn")) {
    var id2 = e.target.getAttribute("data-winid");
    if (wins[id2]) {
      var s = wins[id2].el.style;
      if (s.width === "100%") {
        s.width = "800px"; s.height = "600px"; s.top = "50px"; s.left = "50px";
      } else {
        s.width = "100%"; s.height = "100%"; s.top = "0"; s.left = "0";
      }
    }
  }
});

var drag = null;
document.addEventListener("mousedown", function(e) {
  var head = e.target.closest(".win-head");
  if (!head || e.target.tagName === "BUTTON") return;
  var id = head.getAttribute("data-winid");
  if (!wins[id]) return;
  var el = wins[id].el;
  if (el.style.width === "100%") return;
  drag = { id: id, dx: e.clientX - el.offsetLeft, dy: e.clientY - el.offsetTop };
  e.preventDefault();
});
document.addEventListener("mousemove", function(e) {
  if (!drag) return;
  var el = wins[drag.id].el;
  el.style.left = (e.clientX - drag.dx) + "px";
  el.style.top = (e.clientY - drag.dy) + "px";
});
document.addEventListener("mouseup", function() { drag = null; });

function toggleMenu() {
  var m = document.getElementById("menu");
  m.style.display = m.style.display === "flex" ? "none" : "flex";
}
document.getElementById("winArea").addEventListener("mousedown", function() {
  document.getElementById("menu").style.display = "none";
});
function doShutdown() { ipcRenderer.invoke("quit-app"); }

function addTermLine(container, text, color) {
  var div = document.createElement("div");
  div.style.color = color || "#ccc";
  div.style.whiteSpace = "pre-wrap";
  div.innerText = text;
  container.appendChild(div);
}

function launchApp(appName) {
  document.getElementById("menu").style.display = "none";

  if (appName === "arcade") {
    var aHtml = '<div style="position:absolute;inset:0;display:flex;flex-direction:column;background:#1a0000;font-family:Consolas,monospace;color:#ffd700;">';
    aHtml += '<div style="padding:20px 30px;display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid #ffd700;background:#800000;flex-shrink:0;">';
    aHtml += '<div><div style="font-family:Impact;font-weight:900;font-size:1.6rem;letter-spacing:5px;color:#ffd700;text-shadow:3px 3px 0 #000;">\u2605 STATE ARCADE BUREAU \u2605</div>';
    aHtml += '<div style="font-size:10px;color:#ff3333;letter-spacing:4px;">LENINOS v3.2 - PARTY-APPROVED RECREATION</div></div>';
    aHtml += '<input type="text" class="arc-si" placeholder="SEARCH..." style="width:300px;background:#0a0000;border:2px solid #cc0000;padding:10px;color:#ff3333;outline:none;text-align:center;font-family:Consolas;font-size:13px;letter-spacing:2px;">';
    aHtml += '</div>';
    aHtml += '<div class="arc-bd" style="flex:1;padding:20px;overflow-y:auto;">';
    aHtml += '<div class="arc-ct" style="font-size:11px;color:#ff3333;margin-bottom:12px;padding:6px 10px;border-left:3px solid #cc0000;background:rgba(128,0,0,0.15);"></div>';
    aHtml += '<div class="arc-gr" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:10px;"></div>';
    aHtml += '</div>';
    aHtml += '<div style="height:30px;background:#2b0000;border-top:3px solid #ffd700;display:flex;align-items:center;justify-content:center;font-size:9px;color:#cc0000;letter-spacing:3px;flex-shrink:0;">ALL RECREATIONAL SOFTWARE IS PROPERTY OF THE STATE</div>';
    aHtml += '<div class="arc-gv" style="position:absolute;inset:0;background:#000;display:none;flex-direction:column;z-index:10;">';
    aHtml += '<div style="height:42px;background:#800000;border-bottom:3px solid #ffd700;display:flex;align-items:center;padding:0 12px;gap:12px;flex-shrink:0;">';
    aHtml += '<button class="arc-bk" style="background:#cc0000;border:2px solid #ffd700;color:#ffd700;padding:5px 14px;cursor:pointer;font-weight:bold;font-family:Consolas;letter-spacing:2px;font-size:10px;">\u25C0 RETREAT</button>';
    aHtml += '<span class="arc-gt" style="color:#ffd700;letter-spacing:3px;font-weight:bold;font-size:10px;"></span></div>';
    aHtml += '<iframe class="arc-fr" style="flex:1;border:none;width:100%;height:100%;background:#000;" allow="autoplay; fullscreen; gamepad"></iframe>';
    aHtml += '</div></div>';
    var id = createWin("State Arcade Bureau", 1100, 750, aHtml, false);
    var w = wins[id].el;
    var gr = w.querySelector(".arc-gr");
    var ct = w.querySelector(".arc-ct");
    var si = w.querySelector(".arc-si");
    var gv = w.querySelector(".arc-gv");
    var gt = w.querySelector(".arc-gt");
    var gf = w.querySelector(".arc-fr");
    var bk = w.querySelector(".arc-bk");
    var gl = [$gamesJsArray];
    gl.sort();
    function arcRender(term) {
      gr.innerHTML = "";
      var fil = gl.filter(function(x) { return x.toLowerCase().indexOf((term || "").toLowerCase()) !== -1; });
      ct.textContent = "\u2605 " + fil.length + " OF " + gl.length + " PROGRAMS CATALOGUED";
      fil.forEach(function(gm) {
        var dn = gm.indexOf("cl") === 0 ? gm.substring(2) : gm;
        var card = document.createElement("div");
        card.title = dn;
        card.style.cssText = "cursor:pointer;height:75px;display:flex;align-items:center;justify-content:center;background:#200000;border:2px solid #500000;padding:10px;text-align:center;overflow:hidden;box-shadow:3px 3px 0 #000;transition:all 0.2s;";
        card.onmouseover = function() { card.style.background = "#400000"; card.style.borderColor = "#ffd700"; };
        card.onmouseout = function() { card.style.background = "#200000"; card.style.borderColor = "#500000"; };
        var h3 = document.createElement("span");
        h3.textContent = dn;
        h3.style.cssText = "font-size:9px;letter-spacing:1px;font-weight:bold;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;width:100%;color:#ffd700;";
        card.appendChild(h3);
        card.onclick = function() {
          gt.textContent = "\u2605 EXECUTING: " + dn.toUpperCase();
          gv.style.display = "flex";
          fetch("https://cdn.jsdelivr.net/gh/bubbls/ugs-singlefile/UGS-Files/" + encodeURIComponent(gm) + ".html")
            .then(function(r) { return r.text(); })
            .then(function(html) {
              var parser = new DOMParser();
              var doc = parser.parseFromString(html, "text/html");
              var pre = doc.querySelector("pre");
              var raw = pre ? pre.textContent : html;
              gf.contentDocument.open();
              gf.contentDocument.write(raw);
              gf.contentDocument.close();
            }).catch(function(err) { console.error("Failed:", err); });
        };
        gr.appendChild(card);
      });
    }
    bk.onclick = function() { gv.style.display = "none"; gf.src = "about:blank"; };
    si.oninput = function() { arcRender(si.value); };
    arcRender("");
  }

  if (appName === "underground") {
    ipcRenderer.invoke("get-proxy-port").then(function(port) {
      var navHtml = '<div class="browser-nav underground-nav">' +
        '<button class="nav-btn underground-btn ubrowser-back">&lt;</button>' +
        '<button class="nav-btn underground-btn ubrowser-fwd">&gt;</button>' +
        '<input class="url-bar underground-url ubrowser-url" value="https://www.google.com">' +
        '<button class="nav-btn underground-btn ubrowser-go">GO</button>' +
        '<button class="nav-btn underground-btn ubrowser-home" title="Home">H</button>' +
        '</div>';
      var wvHtml = '<div class="browser-webview-wrap"><webview class="ubrowser-wv" src="https://www.google.com" allowpopups partition="persist:underground"></webview></div>';
      var statusHtml = '<div class="underground-status">' +
        '<span><span class="underground-dot"></span> PROXY ACTIVE</span>' +
        '<span>PORT: ' + port + '</span>' +
        '<span>MODE: UNRESTRICTED</span>' +
        '<span>ENCRYPTION: ACTIVE</span>' +
        '<span class="ubrowser-status-url" style="flex:1;text-align:right;opacity:0.6">Ready</span>' +
        '</div>';
      var id = createWin("Underground Net [UNRESTRICTED]", 1100, 750, navHtml + wvHtml + statusHtml, true);
      var winEl = wins[id].el;
      var wv = winEl.querySelector(".ubrowser-wv");
      var urlBar = winEl.querySelector(".ubrowser-url");
      var statusUrl = winEl.querySelector(".ubrowser-status-url");
      function navigateU(rawUrl) {
        var u = rawUrl.trim();
        if (!u) return;
        if (u.indexOf("://") === -1) {
          if (u.indexOf(".") !== -1 && u.indexOf(" ") === -1) {
            u = "https://" + u;
          } else {
            u = "https://www.google.com/search?q=" + encodeURIComponent(u);
          }
        }
        wv.loadURL(u);
      }
      winEl.querySelector(".ubrowser-back").onclick = function() { if (wv.canGoBack()) wv.goBack(); };
      winEl.querySelector(".ubrowser-fwd").onclick = function() { if (wv.canGoForward()) wv.goForward(); };
      winEl.querySelector(".ubrowser-go").onclick = function() { navigateU(urlBar.value); };
      winEl.querySelector(".ubrowser-home").onclick = function() { urlBar.value = "https://www.google.com"; navigateU("https://www.google.com"); };
      urlBar.addEventListener("keydown", function(e) { if (e.key === "Enter") navigateU(urlBar.value); });
      wv.addEventListener("did-navigate", function(e) { urlBar.value = e.url; statusUrl.innerText = e.url; });
      wv.addEventListener("did-navigate-in-page", function(e) { urlBar.value = e.url; statusUrl.innerText = e.url; });
      wv.addEventListener("did-start-loading", function() { statusUrl.innerText = "Loading..."; });
      wv.addEventListener("did-stop-loading", function() { statusUrl.innerText = urlBar.value; });
      wv.addEventListener("did-fail-load", function(e) {
        if (e.errorCode !== -3) { statusUrl.innerText = "Error: " + e.errorDescription; }
      });
    });
  }

  if (appName === "browser") {
    var bHtml = '<div class="browser-nav"><button class="nav-btn browser-back">&lt;</button><button class="nav-btn browser-fwd">&gt;</button><input class="url-bar browser-url" value="https://search.brave.com"><button class="nav-btn browser-go">GO</button></div><div class="browser-webview-wrap"><webview class="browser-wv" src="https://search.brave.com" allowpopups></webview></div>';
    var id = createWin("Propaganda Net", 1000, 700, bHtml, false);
    var winEl = wins[id].el;
    var wv = winEl.querySelector(".browser-wv");
    var urlBar = winEl.querySelector(".browser-url");
    winEl.querySelector(".browser-back").onclick = function() { if (wv.canGoBack()) wv.goBack(); };
    winEl.querySelector(".browser-fwd").onclick = function() { if (wv.canGoForward()) wv.goForward(); };
    winEl.querySelector(".browser-go").onclick = function() {
      var u = urlBar.value.trim();
      if (u.indexOf("://") === -1) u = "https://search.brave.com/search?q=" + encodeURIComponent(u);
      wv.loadURL(u);
    };
    urlBar.addEventListener("keydown", function(e) {
      if (e.key === "Enter") {
        var u = urlBar.value.trim();
        if (u.indexOf("://") === -1) u = "https://search.brave.com/search?q=" + encodeURIComponent(u);
        wv.loadURL(u);
      }
    });
    wv.addEventListener("did-navigate", function(e) { urlBar.value = e.url; });
    wv.addEventListener("did-navigate-in-page", function(e) { urlBar.value = e.url; });
  }

  if (appName === "gallery") {
    var imgs = [
      { t: "Sputnik", u: "https://upload.wikimedia.org/wikipedia/commons/thumb/b/be/Sputnik_asm.jpg/440px-Sputnik_asm.jpg" },
      { t: "Vladimir Lenin", u: "https://cdn.britannica.com/13/59613-004-FF09F9D8/Vladimir-Ilich-Lenin-1918.jpg" },
      { t: "Yuri Gagarin", u: "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Yuri_Gagarin_%281961%29.jpg/440px-Yuri_Gagarin_%281961%29.jpg" },
      { t: "Hammer and Sickle", u: "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/Hammer_and_sickle.svg/440px-Hammer_and_sickle.svg.png" },
      { t: "Soviet Flag", u: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Flag_of_the_Soviet_Union.svg/440px-Flag_of_the_Soviet_Union.svg.png" }
    ];
    var gHtml = '<div class="gallery-view"><img class="gallery-img" src="' + imgs[0].u + '"><div class="gallery-cap">' + imgs[0].t + '</div></div><div class="gallery-nav"><button class="gallery-prev-btn">PREV</button><span class="gallery-counter">1 / ' + imgs.length + '</span><button class="gallery-next-btn">NEXT</button></div>';
    var id = createWin("Communist Gallery", 850, 620, gHtml, false);
    var winEl = wins[id].el;
    var imgEl = winEl.querySelector(".gallery-img");
    var capEl = winEl.querySelector(".gallery-cap");
    var counterEl = winEl.querySelector(".gallery-counter");
    var gIdx = 0;
    function updateGallery() {
      imgEl.src = imgs[gIdx].u;
      capEl.innerText = imgs[gIdx].t;
      counterEl.innerText = (gIdx + 1) + " / " + imgs.length;
    }
    winEl.querySelector(".gallery-next-btn").onclick = function() { gIdx = (gIdx + 1) % imgs.length; updateGallery(); };
    winEl.querySelector(".gallery-prev-btn").onclick = function() { gIdx = (gIdx - 1 + imgs.length) % imgs.length; updateGallery(); };
  }

  if (appName === "term") {
    var tHtml = '<div class="term"><div style="color:#ff3333">==============================</div><div style="color:#ffd700"> LENINOS v3.2 Terminal</div><div style="color:#ff3333">==============================</div><div style="color:#888">Type help for commands.</div><br></div><input class="term-in" placeholder="Enter command, comrade...">';
    var id = createWin("Peoples Terminal", 750, 450, tHtml, false);
    var winEl = wins[id].el;
    var termDiv = winEl.querySelector(".term");
    var termInput = winEl.querySelector(".term-in");
    var quotes = [
      "The goal of socialism is communism. - Lenin",
      "There are decades where nothing happens; and weeks where decades happen. - Lenin"
    ];
    termInput.addEventListener("keydown", function(e) {
      if (e.key !== "Enter") return;
      var cmd = termInput.value.trim();
      if (!cmd) return;
      termInput.value = "";
      var prompt = document.createElement("div");
      prompt.innerHTML = '<span style="color:#ff3333">comrade@leninos</span>:<span style="color:#4444ff">~</span> ' + cmd;
      termDiv.appendChild(prompt);
      if (cmd === "help") {
        addTermLine(termDiv, "Commands: help, clear, sysinfo, glory, quote, underground, exec [cmd]", "#ffd700");
      } else if (cmd === "clear") {
        termDiv.innerHTML = "";
      } else if (cmd === "underground") {
        addTermLine(termDiv, "\u2691 Initializing Underground Net... Access granted, comrade.", "#00ff41");
        setTimeout(function() { launchApp("underground"); }, 300);
      } else if (cmd === "sysinfo") {
        ipcRenderer.invoke("get-sysinfo").then(function(info) {
          addTermLine(termDiv, "User: " + info.user, "#ffd700");
          addTermLine(termDiv, "Host: " + info.host, "#ffd700");
          addTermLine(termDiv, "OS: " + info.os, "#ffd700");
          addTermLine(termDiv, "Arch: " + info.arch, "#ffd700");
          addTermLine(termDiv, "CPUs: " + info.cpus, "#ffd700");
          addTermLine(termDiv, "Memory: " + info.mem + "MB", "#ffd700");
          termDiv.scrollTop = termDiv.scrollHeight;
        });
      } else if (cmd === "glory") {
        addTermLine(termDiv, "\u2605 GLORY TO THE WORKERS STATE! \u2605", "#ff3333");
      } else if (cmd === "quote") {
        addTermLine(termDiv, quotes[Math.floor(Math.random() * quotes.length)], "#ffd700");
      } else if (cmd.indexOf("exec ") === 0) {
        ipcRenderer.invoke("exec-command", cmd.substring(5)).then(function(res) {
          if (res.stderr && res.stderr.indexOf("BLOCKED") === 0) {
            addTermLine(termDiv, res.stderr, "#ff0000");
          } else {
            addTermLine(termDiv, (res.stdout || res.stderr || "(no output)").trim(), "#ccc");
          }
          termDiv.scrollTop = termDiv.scrollHeight;
        });
      } else {
        addTermLine(termDiv, "Unknown command. The Party suggests help.", "#cc0000");
      }
      termDiv.scrollTop = termDiv.scrollHeight;
    });
    setTimeout(function() { termInput.focus(); }, 100);
  }

  if (appName === "files") {
    var fHtml = '<div class="file-toolbar"><button class="nav-btn file-up-btn">UP</button><input class="file-path" value=""></div><div class="file-list"></div>';
    var id = createWin("State Archives", 750, 500, fHtml, false);
    var winEl = wins[id].el;
    var pathInput = winEl.querySelector(".file-path");
    var fileList = winEl.querySelector(".file-list");
    var currentPath = "";
    function loadDir(dirPath) {
      ipcRenderer.invoke("read-dir", dirPath).then(function(entries) {
        currentPath = dirPath;
        pathInput.value = dirPath;
        fileList.innerHTML = "";
        if (entries.error) {
          fileList.innerHTML = '<div class="file-item" style="color:red">ACCESS DENIED: ' + entries.error + '</div>';
          return;
        }
        entries.sort(function(a, b) {
          if (a.isDir && !b.isDir) return -1;
          if (!a.isDir && b.isDir) return 1;
          return a.name.localeCompare(b.name);
        });
        entries.forEach(function(entry) {
          var item = document.createElement("div");
          item.className = "file-item " + (entry.isDir ? "file-dir" : "file-file");
          item.innerHTML = '<span class="file-icon">' + (entry.isDir ? "[DIR]" : "[FILE]") + '</span>' + entry.name;
          if (entry.isDir) {
            item.ondblclick = function() {
              var sep = currentPath.endsWith("\\") ? "" : "\\";
              loadDir(currentPath + sep + entry.name);
            };
          }
          fileList.appendChild(item);
        });
      });
    }
    winEl.querySelector(".file-up-btn").onclick = function() {
      var parent = pathModule.dirname(currentPath);
      if (parent && parent !== currentPath) loadDir(parent);
    };
    pathInput.addEventListener("keydown", function(e) {
      if (e.key === "Enter") loadDir(pathInput.value);
    });
    ipcRenderer.invoke("get-homedir").then(function(home) { loadDir(home); });
  }

  if (appName === "sys") {
    var sHtml = '<div class="sysinfo"><div style="text-align:center;color:#888">Loading...</div></div>';
    var id = createWin("5-Year Plan", 650, 500, sHtml, false);
    var winEl = wins[id].el;
    var sysDiv = winEl.querySelector(".sysinfo");
    ipcRenderer.invoke("get-sysinfo").then(function(info) {
      var memUsed = info.mem - info.freemem;
      var memPct = Math.round((memUsed / info.mem) * 100);
      var uptimeH = Math.floor(info.uptime / 3600);
      var uptimeM = Math.floor((info.uptime % 3600) / 60);
      sysDiv.innerHTML = '<h2>\u2605 5-YEAR PLAN STATUS</h2>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">COMRADE:</div><div class="sysinfo-value">' + info.user + '</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">MACHINE:</div><div class="sysinfo-value">' + info.host + '</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">KERNEL:</div><div class="sysinfo-value">' + info.os + '</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">ARCH:</div><div class="sysinfo-value">' + info.arch + '</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">CPU WORKERS:</div><div class="sysinfo-value">' + info.cpus + ' united</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">MEMORY:</div><div class="sysinfo-value">' + info.mem + 'MB shared equally</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">MEM USAGE:</div><div class="sysinfo-value">' + memUsed + ' / ' + info.mem + 'MB (' + memPct + '%)<div class="sysinfo-bar"><div class="sysinfo-fill" style="width:' + memPct + '%"></div></div></div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">UPTIME:</div><div class="sysinfo-value">' + uptimeH + 'h ' + uptimeM + 'm</div></div>' +
        '<div class="sysinfo-row"><div class="sysinfo-label">5-YEAR PLAN:</div><div class="sysinfo-value" style="color:#0f0">ON TRACK</div></div>' +
        '<br><div style="text-align:center;color:#ff3333;font-size:16px">\u2605 ALL RESOURCES BELONG TO THE PEOPLE \u2605</div>';
    });
  }
}
</script>
</body>
</html>
"@

[IO.File]::WriteAllText('leninos-src\index.html', $html, [Text.Encoding]::UTF8)
Log 'index.html written.'

# ============================================================
# NPM INSTALL AND PACKAGE
# ============================================================
Log 'Assembling resources...'
$env:PATH = (Join-Path $PSScriptRoot 'node') + ';' + $env:PATH
Set-Location 'leninos-src'

# Switch to Continue so npm warnings dont kill the script
$ErrorActionPreference = 'Continue'

if (-not (Test-Path 'node_modules\electron')) {
    Log 'Installing Electron...'
    $npmOut = & ..\node\npm.cmd install electron@latest --save --no-optional 2>&1
    $npmOut | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path 'node_modules\electron')) {
        Log 'FATAL: Electron install actually failed'
        exit 1
    }
    Log 'Electron installed.'
}
if (-not (Test-Path 'node_modules\@electron\packager')) {
    Log 'Installing Packager...'
    $npmOut = & ..\node\npm.cmd install @electron/packager --save-dev 2>&1
    $npmOut | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path 'node_modules\@electron\packager')) {
        Log 'FATAL: Packager install actually failed'
        exit 1
    }
    Log 'Packager installed.'
}

Log 'Packaging executable...'
$packOut = & ..\node\npx.cmd @electron/packager . LeninOS --platform=win32 --arch=x64 --out=..\build --overwrite --no-prune 2>&1
$packOut | ForEach-Object { Write-Host $_ }

# Switch back to Stop for remaining logic
$ErrorActionPreference = 'Stop'

Set-Location ..

if (Test-Path 'build\LeninOS-win32-x64\LeninOS.exe') {
    Move-Item 'build\LeninOS-win32-x64' 'LeninOS-win32-x64' -Force
    Remove-Item 'build' -Recurse -Force -ErrorAction SilentlyContinue
    Log 'BUILD COMPLETE - LeninOS-win32-x64\LeninOS.exe'
    exit 0
} else {
    Log 'Packaging failed. Attempting dev mode launch...'
    Set-Location 'leninos-src'
    & ..\node\npx.cmd electron . 2>&1 | ForEach-Object { Write-Host $_ }
    Set-Location ..
    exit 1
}
if (-not (Test-Path 'node_modules\electron')) {
    Log 'Installing Electron...'
    $npmOut = & ..\node\npm.cmd install electron@latest --save --no-optional 2>&1
    $npmOut | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path 'node_modules\electron')) {
        Log 'FATAL: Electron install actually failed'
        exit 1
    }
    Log 'Electron installed.'
}
if (-not (Test-Path 'node_modules\@electron\packager')) {
    Log 'Installing Packager...'
    $npmOut = & ..\node\npm.cmd install @electron/packager --save-dev 2>&1
    $npmOut | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path 'node_modules\@electron\packager')) {
        Log 'FATAL: Packager install actually failed'
        exit 1
    }
    Log 'Packager installed.'
}

Log 'Packaging executable...'
$packOut = & ..\node\npx.cmd @electron/packager . LeninOS --platform=win32 --arch=x64 --out=..\build --overwrite --no-prune 2>&1
$packOut | ForEach-Object { Write-Host $_ }

$ErrorActionPreference = 'Stop'
Set-Location ..

if (Test-Path 'build\LeninOS-win32-x64\LeninOS.exe') {
    Move-Item 'build\LeninOS-win32-x64' 'LeninOS-win32-x64' -Force
    Remove-Item 'build' -Recurse -Force -ErrorAction SilentlyContinue
    Log 'BUILD COMPLETE - LeninOS-win32-x64\LeninOS.exe'
    exit 0
} else {
    Log 'Packaging failed. Attempting dev mode launch...'
    Set-Location 'leninos-src'
    & ..\node\npx.cmd electron . 2>&1 | ForEach-Object { Write-Host $_ }
    Set-Location ..
    exit 1
}

} catch {
    $errMsg = $_.Exception.Message
    $errLine = $_.InvocationInfo.ScriptLineNumber
    Log "FATAL ERROR at line $errLine : $errMsg"
    Log $_.ScriptStackTrace
    Write-Host ""
    Write-Host "===== CRASH DETAILS =====" -ForegroundColor Red
    Write-Host "Line: $errLine" -ForegroundColor Red
    Write-Host "Error: $errMsg" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host "=========================" -ForegroundColor Red
    exit 1
}