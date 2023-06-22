/* global BufferEncoding */
import { SerialPort, SerialPortOpenOptions } from 'serialport'
import { Queue } from './queue'
import { wait } from './wait'

export type Keyword = 'money' | 'tens' | 'shockUp' | 'shockDown'

export type ArduinoConfig = {
  serial: SerialPortOpenOptions<any>
  action: Record<Keyword, number>
  log?: boolean
  pulseTime?: number
}

export class Arduino {
  serial: SerialPort
  queue: Queue
  readonly keywords: string[]

  constructor (private config: ArduinoConfig) {
    if (this.config.serial) this.serial = new SerialPort(this.config.serial)
    this.queue = new Queue()
    this.keywords = Array.from(Object.keys(this.config.action))
  }

  private send (type: Keyword, active: boolean) {
    return new Promise<void>((resolve, reject) => {
      const data = Buffer.from([(this.config.action[type] << 1) + (active ? 1 : 0)])
      if (this.config.log) console.log('writing', data, 'to serial')
      if (this.serial) this.serial.write(data, (err) => {
        if (err) return reject(err)
        resolve()
      })
    })
  }

  isKeyword (input: string) {
    return this.keywords.includes(input)
  }

  on (keyword: Keyword) {
    this.queue.add(() => this.send(keyword, true))
  }

  off (keyword: Keyword) {
    this.queue.add(() => this.send(keyword, false))
  }

  async onFor (keyword: Keyword, time: number) {
    this.on(keyword)
    await wait(time)
    this.off(keyword)
  }
}
