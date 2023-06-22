import { CaesarEventSub, EventName } from './eventsub'
import { loadFile } from '@kounadev/loadfile'
import { CaesarEventSubConfig } from '.'
import { Relais, RelaisConfig } from './relais'
import { Arduino, ArduinoConfig, Keyword } from './arduino'
import { Taser, TaserConfig } from './taser'
import { Queue } from './queue'
import express, { Handler } from 'express'
import bodyParser from 'body-parser'
import bcrypt from 'bcrypt'
import compression from 'compression'

type Credentials = {
  username: string
  password: string
}

export type Config = {
  eventSub: CaesarEventSubConfig
  relais?: RelaisConfig
  arduino?: ArduinoConfig
  taser?: TaserConfig
  time: {
    sub: number
    bit: number
    control: number
  }
  minBits: number
  api: {
    port: number
    hostname?: string
    credentials?: Credentials[]
  }
}

const createAuthMiddleware:{(creds: Credentials[]): Handler} = function (creds) {
  return function (req, res, next) {
    const authHeader = req.headers.authorization

    if (!authHeader) {
      return res.sendStatus(401)
    }

    const [method, data, ...rest] = authHeader.split(/\s/)

    if (method.toLowerCase() !== 'basic') {
      return res.sendStatus(401)
    }

    const [username, password] = Buffer.from(data, 'base64').toString().split(':')

    const cred = creds.find(cred => cred.username === username)

    bcrypt.compare(password, cred.password)
      .then(result => {
        if (result) {
          next()
        } else {
          res.sendStatus(401)
        }
      })
      .catch(err => {
        console.error(err)
        if (!res.headersSent) {
          res.sendStatus(401)
        }
      })
  }
}

export async function main () {
  const config = await loadFile<Config>('config.js')
  const esub = new CaesarEventSub(config.eventSub)
  let relais:Relais
  let arduino:Arduino
  let taser:Taser
  const queue = new Queue()
  
  if (config.relais) relais = new Relais(config.relais)
  if (config.arduino) arduino = new Arduino(config.arduino)
  if (config.taser) {
    taser = new Taser(config.taser)
      .on('dec', async (power) => {
        if (arduino) await arduino.onFor('shockDown', config.time.control)
        console.log('taser power has been decreased to power', power)
      })
      .on('inc', async (power) => {
        if (arduino) await arduino.onFor('shockUp', config.time.control)
        console.log('taser power has been increased to power', power)
      })

    console.log('taser config:', config.taser)
  }

  esub.on(EventName.SUB, e => {
    if (!e.isGift) {
      if (relais) queue.add(() => relais.onFor('relais', config.time.sub))
      if (arduino) queue.add(() => arduino.onFor('money', config.time.sub))
    }
  })

  esub.on(EventName.GIFTSUB, e => {
    if (relais) queue.add(() => relais.onFor('relais', config.time.sub * e.amount))
    if (arduino) queue.add(() => arduino.onFor('money', config.time.sub * e.amount))
  })

  esub.on(EventName.CHEER, e => {
    if (e.bits >= config.minBits) {
      if (relais) queue.add(() => relais.onFor('relais', config.time.bit * e.bits))
      if (arduino) queue.add(() => arduino.onFor('money', config.time.bit * e.bits))
    }
  })

  esub.on(EventName.POINTSDOWN, e => {
    if (taser) taser.decreasePower()
  })

  esub.on(EventName.POINTSUP, e => {
    if (taser) taser.increasePower()
  })
  
  const app = express()

  if (Array.isArray(config.api.credentials) && config.api.credentials.length) {
    console.log('using auth middleware')
    app.use(createAuthMiddleware(config.api.credentials))
  }
  app.use(compression())
  app.use(bodyParser.json())

  if (arduino) {
    app.post('/arduino/:keyword/:command', (req, res) => {
      const { keyword, command } = req.params
  
      if (!arduino.isKeyword(keyword)) {
        return res.status(400).end('Illegal Keyword')
      }
  
      switch (command.toLowerCase()) {
        case 'on':
          arduino.on(keyword as Keyword)
          res.sendStatus(200)
          break
        case 'onfor':
          const { t } = req.query
          arduino.onFor(keyword as Keyword, t ? Number(t) : 1000)
            .then(() => res.sendStatus(200))
            .catch(err => {
              console.error(err)
              res.sendStatus(500)
            })
          break
        case 'off':
          arduino.off(keyword as Keyword)
          res.sendStatus(200)
          break
        default:
          res.status(400).end('Unknown Command')
          break
      }
    })
    console.log('API using', '/arduino/:keyword/:command')
    console.log('- keywords:', arduino.keywords)
    console.log('- commands', ['on', 'off', 'onfor'])
    console.log('the command \'onfor\' allows for query parameter \'t\' to give the time in ms')
  }

  app.listen(config.api.port, config.api.hostname, () => {
    console.log(`API listening on ${config.api.hostname || 'localhost'}:${config.api.port}`)
  })

  await esub.init()
}
