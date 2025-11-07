'use strict';
/* PeppyMeterBasic – Bookworm (Volumio 4)
 * Adds optional “Camilla FIFO / Monitor” backend alongside default ALSA loopback.
 * Safe across x86 / Pi4 / Pi5. No edits to CamillaDSP YAML; optional systemd drop-in adds ordering.
 */

const fs = require('fs-extra');
const libFsExtra = require('fs-extra');
const exec = require('child_process').exec;
const execSync = require('child_process').execSync;
const libQ = require('kew');
const path = require('path');
const io = require('socket.io-client');

const meterspath = 'INTERNAL/PeppyMeterBasic/Templates/';
const logPrefix = 'PeppyMeterBasic --- ';

// Define the class
module.exports = peppymeterbasic;

function peppymeterbasic(context) {
  const self = this;
  self.context = context;
  self.commandRouter = self.context.coreCommand;
  self.logger = self.commandRouter.logger;
  this.context = context;
  this.commandRouter = this.context.coreCommand;
  this.logger = this.context.logger;
  this.configManager = this.context.configManager;
  this.socket = null;
  this._camillaDropIn = '/etc/systemd/system/peppymeterbasic.service.d/10-camilla.conf';
}

/* -------------------- Volumio lifecycle -------------------- */

peppymeterbasic.prototype.onVolumioStart = function () {
  const self = this;
  const configFile = self.commandRouter.pluginManager.getConfigurationFile(self.context, 'config.json');
  self.config = new (require('v-conf'))();
  self.config.loadFile(configFile);
  return libQ.resolve();
};

peppymeterbasic.prototype.getConfigurationFiles = function () {
  return ['config.json'];
};

peppymeterbasic.prototype.getI18nFile = function (langCode) {
  const i18nFiles = fs.readdirSync(path.join(__dirname, 'i18n'));
  const langFile = 'strings_' + langCode + '.json';
  if (i18nFiles.some((f) => f === langFile)) {
    return path.join(__dirname, 'i18n', langFile);
  }
  return path.join(__dirname, 'i18n', 'strings_en.json');
};

peppymeterbasic.prototype.onStart = function () {
  const self = this;
  const defer = libQ.defer();

  // Socket → start/stop meter on play/pause
  self.socket = io.connect('http://localhost:3000');
  self._wirePlaybackState();

  // Always refresh ALSA base config (as original plugin does)
  self.commandRouter.executeOnPlugin('audio_interface', 'alsa_controller', 'updateALSAConfigFile')
    .then(() => {
      // Backend selection
      const backend = self.config.get('backend') || 'loopback';
      if (backend === 'camilla_fifo') {
        return self._startCamillaFifoMode();
      } else {
        return self._startLoopbackMode();
      }
    })
    .then(() => {
      self.commandRouter.pushToastMessage('success', 'Starting peppymeterbasic');
      defer.resolve();
    })
    .fail((err) => {
      self.logger.error(logPrefix + 'onStart failed: ' + err);
      defer.resolve(); // don’t block Volumio startup
    });

  return defer.promise;
};

peppymeterbasic.prototype.onStop = function () {
  const self = this;
  const defer = libQ.defer();

  self.logger.info('Stopping peppymeterbasic service');
  // Stop the systemd service
  exec('/usr/bin/sudo /bin/systemctl stop peppymeterbasic.service', { uid: 1000, gid: 1000 }, () => {
    // Clean Camilla drop-in if present
    try {
      if (fs.existsSync(self._camillaDropIn)) {
        fs.unlinkSync(self._camillaDropIn);
        execSync('systemctl daemon-reload');
      }
    } catch (e) {
      self.logger.error(logPrefix + 'Failed to remove systemd drop-in: ' + e);
    }

    // Optionally remove FIFO (safe to leave; /tmp is ephemeral)
    try {
      const fifo = self.config.get('camillaFifoPath') || '/tmp/basic_peppy_meter_fifo';
      if (fs.existsSync(fifo)) fs.unlinkSync(fifo);
    } catch (e) {
      /* ignore */
    }

    if (self.socket) {
      try { self.socket.off('pushState'); } catch (e) { /* ignore */ }
      try { self.socket.close(); } catch (e) { /* ignore */ }
      self.socket = null;
    }

    defer.resolve();
  });

  return defer.promise;
};

peppymeterbasic.prototype.onRestart = function () {};

/* -------------------- Backends -------------------- */

/** Default ALSA loopback path (original behaviour) */
peppymeterbasic.prototype._startLoopbackMode = function () {
  const self = this;
  const defer = libQ.defer();

  // Load snd_aloop to expose loopback (original code path)
  exec('/usr/bin/sudo /sbin/modprobe snd_aloop index=7 pcm_substreams=2', { uid: 1000, gid: 1000 }, (error) => {
    if (error) {
      self.logger.error(logPrefix + 'failed to load snd_aloop: ' + error);
    } else {
      self.commandRouter.pushConsoleMessage('snd_aloop loaded');
    }

    // Ensure any Camilla drop-in is removed when in loopback mode
    try {
      if (fs.existsSync(self._camillaDropIn)) {
        fs.unlinkSync(self._camillaDropIn);
        execSync('systemctl daemon-reload');
      }
    } catch (e) {
      /* ignore */
    }

    // Create the plugin’s historical FIFO too (harmless if unused)
    const fifo = '/tmp/basic_peppy_meter_fifo';
    try {
      if (!fs.existsSync(fifo)) {
        execSync(`/usr/bin/mkfifo ${fifo}; /bin/chmod 666 ${fifo}`);
      }
    } catch (e) {
      self.logger.warn(logPrefix + 'FIFO creation warning: ' + e);
    }

    defer.resolve();
  });

  return defer.promise;
};

/** Optional Camilla FIFO / Monitor path (no ALSA loopback dependency) */
peppymeterbasic.prototype._startCamillaFifoMode = function () {
  const self = this;
  const defer = libQ.defer();

  const fifo = self.config.get('camillaFifoPath') || '/tmp/basic_peppy_meter_fifo';
  try {
    if (!fs.existsSync(fifo)) {
      execSync(`/usr/bin/mkfifo ${fifo}; /bin/chmod 666 ${fifo}`);
      self.logger.info(logPrefix + `Created FIFO at ${fifo}`);
    }
  } catch (e) {
    self.logger.error(logPrefix + 'Failed to create FIFO: ' + e);
  }

  // Install systemd ordering drop-in so peppymeterbasic starts after Camilla
  try {
    execSync('mkdir -p /etc/systemd/system/peppymeterbasic.service.d');
    fs.writeFileSync(
      self._camillaDropIn,
      '[Unit]\nWants=camilladsp.service\nAfter=camilladsp.service\n',
      'utf8'
    );
    execSync('systemctl daemon-reload');
    self.logger.info(logPrefix + 'Installed systemd drop-in for Camilla ordering');
  } catch (e) {
    self.logger.error(logPrefix + 'Drop-in install failed: ' + e);
  }

  // Do NOT modprobe snd_aloop in this mode

  defer.resolve();
  return defer.promise;
};

/* -------------------- UI / Settings -------------------- */

peppymeterbasic.prototype.getUIConfig = function () {
  const self = this;
  const defer = libQ.defer();
  const lang_code = this.commandRouter.sharedVars.get('language_code');

  self.commandRouter.i18nJson(
    __dirname + '/i18n/strings_' + lang_code + '.json',
    __dirname + '/i18n/strings_en.json',
    __dirname + '/UIConfig.json'
  )
    .then(function (uiconf) {
      // screensize select
      const valuescreen = self.config.get('screensize');
      self.configManager.setUIConfigParam(uiconf, 'sections[0].content[0].value.value', valuescreen);
      self.configManager.setUIConfigParam(uiconf, 'sections[0].content[0].value.label', valuescreen);

      // Build screensize options from default + folders
      const directoryPath = '/data/INTERNAL/PeppyMeterBasic/Templates/';
      let folders = [];
      try {
        const files = fs.readdirSync(directoryPath);
        folders = files.filter((file) => {
          try { return fs.statSync(`${directoryPath}/${file}`).isDirectory(); }
          catch { return false; }
        });
      } catch (err) {
        self.logger.error('Error reading directory: ' + err);
      }
      const folderList = ['320x240', '480x320', '800x480', '1280x400', ...folders];
      folderList.forEach((f) => {
        self.configManager.pushUIConfigParam(uiconf, 'sections[0].content[0].options', { value: f, label: f });
      });

      // Hide unused section elements (keep your plugin’s current behaviour)
      uiconf.sections[1].content[1].hidden = true;
      uiconf.sections[1].content[2].hidden = true;
      uiconf.sections[1].content[3].hidden = true;

      // Screen width/height fields
      uiconf.sections[1].content[1].value = self.config.get('screenwidth');
      uiconf.sections[1].content[1].attributes = [{ placeholder: self.config.get('screenwidth'), min: 0, max: 3500 }];
      uiconf.sections[1].content[2].value = self.config.get('screenheight');
      uiconf.sections[1].content[2].attributes = [{ placeholder: self.config.get('screenheight'), min: 0, max: 3500 }];

      // Meter list (from meters.txt)
      const meterfolder = ['320x240', '480x320', '800x480', '1280x400'].includes(valuescreen)
        ? '/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter/'
        : '/data/INTERNAL/PeppyMeterBasic/Templates/';

      try {
        const idata = fs.readFileSync(`${meterfolder}${valuescreen}/meters.txt`, 'utf8');
        const matches = [...idata.matchAll(/\[(.*?)\]/g)].map((m) => m[1]);
        const meterList = ['random', ...matches];
        meterList.forEach((m) => {
          self.configManager.pushUIConfigParam(uiconf, 'sections[1].content[0].options', { value: m, label: m });
        });
      } catch (err) {
        self.logger.error('Error reading meters.txt: ' + err);
        self.configManager.pushUIConfigParam(uiconf, 'sections[1].content[0].options', { value: 'no config!', label: 'no config!' });
      }

      // Meter currently selected
      const valuemeter = self.config.get('meter');
      self.configManager.setUIConfigParam(uiconf, 'sections[1].content[0].value.value', valuemeter);
      self.configManager.setUIConfigParam(uiconf, 'sections[1].content[0].value.label', valuemeter);

      // Debug section (kept but hidden)
      uiconf.sections[2].content[0].value = self.config.get('debuglog');
      uiconf.sections[2].hidden = true;

      // Download list section
      const zipvalue = self.config.get('zipfile');
      self.configManager.setUIConfigParam(uiconf, 'sections[3].content[0].value.value', zipvalue);
      self.configManager.setUIConfigParam(uiconf, 'sections[3].content[0].value.label', zipvalue);

      try {
        const listf = fs.readFileSync('/data/plugins/user_interface/peppymeterbasic/meterslist.txt', 'utf8');
        const result = listf.split('\n');
        result.forEach((line, i) => {
          const preparedresult = line.split('.')[0];
          self.configManager.pushUIConfigParam(uiconf, 'sections[3].content[0].options', {
            value: preparedresult,
            label: `${i + 1} ${preparedresult}`
          });
        });
      } catch (err) {
        self.logger.error('Failed to read meterslist.txt: ' + err);
      }

      // Delay
      const dvalue = self.config.get('delaymeter');
      uiconf.sections[4].content[0].value = dvalue;

      // Backend section values
      const backend = self.config.get('backend') || 'loopback';
      const fifo = self.config.get('camillaFifoPath') || '/tmp/basic_peppy_meter_fifo';
      const rate = self.config.get('camillaRate') || 176400;
      const ch = self.config.get('camillaChannels') || 2;
      const fmt = self.config.get('camillaFormat') || 'S16_LE';

      self.configManager.setUIConfigParam(uiconf, 'sections[5].content[0].value', backend);
      self.configManager.setUIConfigParam(uiconf, 'sections[5].content[1].value', fifo);
      self.configManager.setUIConfigParam(uiconf, 'sections[5].content[2].value', rate);
      self.configManager.setUIConfigParam(uiconf, 'sections[5].content[3].value', ch);
      self.configManager.setUIConfigParam(uiconf, 'sections[5].content[4].value', fmt);

      return defer.resolve(uiconf);
    })
    .fail(() => defer.reject(new Error()));

  return defer.promise;
};

/* -------------------- UI Save handlers -------------------- */

peppymeterbasic.prototype.savepeppy = function (data) {
  const self = this;
  const defer = libQ.defer();

  function hasX(sz) { return String(sz).includes('x'); }
  const screensize = data['screensize'].value;

  let screenwidth, screenheight, metersizef, myNumberx, myNumbery, myMeterSize, autovalue;

  if (hasX(screensize)) {
    autovalue = screensize.split('x');
  } else {
    myNumberx = '';
    myNumbery = '';
    metersizef = 30;
  }

  if (['320x240','480x320','800x480','1280x400'].includes(screensize)) {
    myNumberx = '';
    myNumbery = '';
    metersizef = 30;
  } else {
    screenwidth = parseInt(autovalue[0], 10);
    screenheight = parseInt(autovalue[1].split('+')[0], 10);
    metersizef = parseInt(autovalue[1].split('+')[1], 10);
    myNumberx = Number.isFinite(screenwidth) ? screenwidth : 480;
    myNumbery = Number.isFinite(screenheight) ? screenheight : 240;
    myMeterSize = Number.isFinite(metersizef) ? metersizef : 30;
  }

  if (isNaN(metersizef)) metersizef = 30;

  self.config.set('screensize', screensize);
  self.config.set('meter', 'random');
  self.config.set('screenwidth', myNumberx || '');
  self.config.set('screenheight', myNumbery || '');
  if (self.config.get('metersize') !== metersizef) {
    self.config.set('metersize', metersizef);
    setTimeout(() => self.updateasound(), 2000);
  }

  self.refreshUI()
    .then(() => {
      self.commandRouter.pushToastMessage('success', 'peppymeterbasic Configuration updated');
      defer.resolve({});
    })
    .fail(() => {
      defer.reject(new Error('error'));
      self.commandRouter.pushToastMessage('error', 'failed to start. Check your config !');
    });

  return defer.promise;
};

peppymeterbasic.prototype.savepeppy1 = function (data) {
  const self = this;
  const defer = libQ.defer();

  self.config.set('meter', data['meter'].value);
  self.savepeppyconfig();
  self.restartpeppyservice()
    .then(() => {
      self.commandRouter.pushToastMessage('success', 'peppymeterbasic Configuration updated');
      defer.resolve({});
    })
    .fail(() => {
      defer.reject(new Error('error'));
      self.commandRouter.pushToastMessage('error', 'failed to start. Check your config !');
    });

  return defer.promise;
};

peppymeterbasic.prototype.savepeppy2 = function (data) {
  const self = this;
  const defer = libQ.defer();

  self.config.set('debuglog', data['debuglog']);
  self.savepeppyconfig();
  self.restartpeppyservice()
    .then(() => {
      self.commandRouter.pushToastMessage('success', 'peppymeterbasic Configuration for debug log updated');
      defer.resolve({});
    })
    .fail(() => {
      defer.reject(new Error('error'));
      self.commandRouter.pushToastMessage('error', 'failed to start. Check your config !');
    });

  return defer.promise;
};

peppymeterbasic.prototype.delaymeter = function (data) {
  const self = this;
  const defer = libQ.defer();

  const delaymeter = data['delaymeter'];
  self.config.set('delaymeter', delaymeter);

  try {
    fs.readFile(__dirname + '/startpeppymeterbasic.sh.tmpl', 'utf8', (err, dataTpl) => {
      if (err) return defer.reject(new Error(err));
      const conf1 = dataTpl.replace('${delaymeter}', delaymeter);
      fs.writeFile('/data/plugins/user_interface/peppymeterbasic/startpeppymeterbasic.sh', conf1, 'utf8', (err2) => {
        if (err2) return defer.reject(new Error(err2));
        self.savepeppyconfig();
        self.restartpeppyservice().then(() => {
          self.commandRouter.pushToastMessage('success', 'peppymeter Configuration updated');
          defer.resolve({});
        }).fail(() => {
          defer.reject(new Error('error'));
          self.commandRouter.pushToastMessage('error', 'failed to start. Check your config !');
        });
      });
    });
  } catch (err) {
    defer.reject(new Error(err));
  }

  return defer.promise;
};

/** NEW: Save backend (loopback vs camilla_fifo) */
peppymeterbasic.prototype.savebackend = function (data) {
  const self = this;
  const defer = libQ.defer();

  const backend = data['backend'];
  const fifo = data['camillaFifoPath'];
  const rate = data['camillaRate'];
  const ch = data['camillaChannels'];
  const fmt = data['camillaFormat'];

  if (backend) self.config.set('backend', backend);
  if (fifo) self.config.set('camillaFifoPath', fifo);
  if (rate) self.config.set('camillaRate', rate);
  if (ch) self.config.set('camillaChannels', ch);
  if (fmt) self.config.set('camillaFormat', fmt);

  // Restart with new backend
  const doStart = () => {
    const b = self.config.get('backend') || 'loopback';
    if (b === 'camilla_fifo') {
      return self._startCamillaFifoMode();
    } else {
      return self._startLoopbackMode();
    }
  };

  self.stopeppyservice();
  doStart();
  self.startpeppyservice();

  self.refreshUI()
    .then(() => {
      self.commandRouter.pushToastMessage('success', 'Backend settings saved');
      defer.resolve({});
    })
    .fail(() => defer.resolve({}));

  return defer.promise;
};

/* -------------------- Core helpers (unchanged behaviour kept) -------------------- */

peppymeterbasic.prototype._wirePlaybackState = function () {
  const self = this;
  if (!self.socket) return;
  self.socket.on('pushState', function (data) {
    self.logger.info(logPrefix + 'status ' + data.status);
    if (data.status === 'play') {
      self.startpeppyservice();
    } else if (data.status === 'pause' || data.status === 'stop') {
      self.stopeppyservice();
    }
  });
};

peppymeterbasic.prototype.startpeppyservice = function () {
  const self = this;
  const defer = libQ.defer();
  exec('/usr/bin/sudo /bin/systemctl start peppymeterbasic.service', { uid: 1000, gid: 1000 }, function (error) {
    if (error) {
      self.logger.info(logPrefix + 'peppymeterbasic failed to start. Check your configuration ' + error);
    } else {
      self.commandRouter.pushConsoleMessage('peppymeterbasic Daemon Started');
    }
    defer.resolve();
  });
  return defer.promise;
};

peppymeterbasic.prototype.restartpeppyservice = function () {
  const self = this;
  const defer = libQ.defer();
  exec('/usr/bin/sudo /bin/systemctl restart peppymeterbasic.service', { uid: 1000, gid: 1000 }, function (error) {
    if (error) {
      self.logger.info(logPrefix + 'peppymeterbasic failed to start. Check your configuration ' + error);
    } else {
      self.commandRouter.pushConsoleMessage('peppymeterbasic Daemon Started');
    }
    defer.resolve();
  });
  return defer.promise;
};

peppymeterbasic.prototype.stopeppyservice = function () {
  const self = this;
  const defer = libQ.defer();
  exec('/usr/bin/sudo /bin/systemctl stop peppymeterbasic.service', { uid: 1000, gid: 1000 }, function (error) {
    if (error) {
      self.logger.info(logPrefix + 'peppymeterbasic failed to stop!! ' + error);
    } else {
      self.commandRouter.pushConsoleMessage('peppymeterbasic Daemon Stop');
    }
    defer.resolve();
  });
  return defer.promise;
};

/* Existing methods preserved: buildasound, updateasound, savepeppyconfig, dlmeter, updatelist, etc. */

peppymeterbasic.prototype.buildasound = function () {
  const self = this;
  const defer = libQ.defer();
  const metersize = self.config.get('metersize');
  try {
    fs.readFile(__dirname + '/peppy_in.peppy_out.6.conf.tmpl', 'utf8', function (err, data) {
      if (err) { defer.reject(new Error(err)); return; }
      const conf1 = data.replace('${metersize}', metersize);
      fs.writeFile('/data/plugins/user_interface/peppymeterbasic/asound/peppy_in.peppy_out.6.conf', conf1, 'utf8', function (err2) {
        if (err2) defer.reject(new Error(err2));
        else defer.resolve();
      });
    });
  } catch (err) {}
  return defer.promise;
};

peppymeterbasic.prototype.updateasound = function () {
  const self = this;
  const defer = libQ.defer();
  self.buildasound()
    .then(() => self.commandRouter.executeOnPlugin('audio_interface', 'alsa_controller', 'updateALSAConfigFile'))
    .then(() => { self.commandRouter.pushToastMessage('success', 'meter size applied'); defer.resolve(); })
    .fail(() => { self.commandRouter.pushToastMessage('error', 'a problem occurred'); defer.reject(); });
  return defer.promise;
};

peppymeterbasic.prototype.savepeppyconfig = function () {
  const self = this;
  const defer = libQ.defer();
  try {
    fs.readFile(__dirname + '/config.txt.tmpl', 'utf8', function (err, dataTpl) {
      if (err) { defer.reject(new Error(err)); return; }

      const screensize = self.config.get('screensize');
      let basefolder = '';
      let screenwidth = self.config.get('screenwidth');
      let screenheight = self.config.get('screenheight');

      if (!['320x240','480x320','800x480','1280x400'].includes(screensize)) {
        basefolder = '/data/INTERNAL/PeppyMeterBasic/Templates';
      }

      let meter = self.config.get('meter');
      if (meter === 'random') meter = 'random';

      const metersize = self.config.get('metersize');
      const debuglogd = self.config.get('debuglog') ? 'True' : 'False';

      const conf1 = dataTpl
        .replace('${meter}', meter)
        .replace('${basefolder}', basefolder)
        .replace('${screensize}', screensize)
        .replace('${screenwidth}', screenwidth)
        .replace('${screenheight}', screenheight)
        .replace('${metersize}', metersize)
        .replace('${debuglog}', debuglogd);

      fs.writeFile('/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter/config.txt', conf1, 'utf8', function (err2) {
        if (err2) { defer.reject(new Error(err2)); }
        else { defer.resolve(); }
      });
    });
  } catch (err) {}
  return defer.promise;
};

peppymeterbasic.prototype.dlmeter = function (data) {
  const self = this;
  const zipfile = data['zipfile'].value;

  return new Promise((resolve) => {
    try {
      const modalData = {
        title: self.commandRouter.getI18nString('METER_INSTALL_TITLE'),
        message: self.commandRouter.getI18nString('METER_INSTALL_WAIT'),
        size: 'lg'
      };
      self.commandRouter.broadcastMessage('openModal', modalData);

      execSync(`/usr/bin/wget -P /tmp https://github.com/balbuze/Meter-peppymeter/raw/main/Zipped-folders/${zipfile}.zip`);
      execSync(`miniunzip -o /tmp/${zipfile}.zip -d /data/${meterspath} && sudo chmod -R 777 /data/${meterspath}`);
      self.refreshUI();
    } catch (err) {
      self.logger.error(logPrefix + 'An error occurs while downloading or installing Meter');
      self.commandRouter.pushToastMessage('error', 'An error occurs while downloading or installing Meter');
    }
    try { execSync(`/bin/rm /tmp/${zipfile}.zip*`); } catch (e) {}
    resolve();
  });
};

peppymeterbasic.prototype.updatelist = function () {
  const self = this;
  const defer = libQ.defer();
  const toDownload = 'https://github.com/balbuze/Meter-peppymeter/raw/main/meterslist.txt';
  try {
    execSync(`/usr/bin/wget '${toDownload}' -O '/data/plugins/user_interface/peppymeterbasic/meterslist.txt'`, { uid: 1000, gid: 1000 });
    self.commandRouter.pushToastMessage('info', self.commandRouter.getI18nString('LIST_SUCCESS_UPDATED'));
    self.refreshUI();
    defer.resolve();
  } catch (err) {
    self.commandRouter.pushToastMessage('error', self.commandRouter.getI18nString('LIST_FAIL_UPDATE'));
    self.logger.error(logPrefix + ' failed to download file ' + err);
    defer.resolve(); // don’t break UI
  }
  return defer.promise;
};

peppymeterbasic.prototype.refreshUI = function () {
  const self = this;
  setTimeout(function () {
    const respconfig = self.commandRouter.getUIConfigOnPlugin('user_interface', 'peppymeterbasic', {});
    respconfig.then(function (config) {
      self.commandRouter.broadcastMessage('pushUiConfig', config);
    });
    self.commandRouter.closeModals();
  }, 100);
};

peppymeterbasic.prototype.getAdditionalConf = function (type, controller, data) {
  const self = this;
  return self.commandRouter.executeOnPlugin(type, controller, 'getConfigParam', data);
};

peppymeterbasic.prototype.setUIConfig = function () {};
peppymeterbasic.prototype.getConf = function () {};
peppymeterbasic.prototype.setConf = function () {};
