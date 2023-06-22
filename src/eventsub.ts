import { ApiClient } from '@twurple/api'
import { ClientCredentialsAuthProvider } from '@twurple/auth'
import { AuthServerConfig, AuthServer } from './authserver'
import {
  ConnectionAdapter,
  DirectConnectionAdapter,
  DirectConnectionAdapterConfig,
  EventSubChannelCheerEvent,
  EventSubChannelSubscriptionEvent,
  EventSubChannelSubscriptionGiftEvent,
  EventSubListener,
  EventSubSubscription,
  ReverseProxyAdapter,
  ReverseProxyAdapterConfig,
} from '@twurple/eventsub'
import EventEmitter from 'events'
import prompts from 'prompts'
import stringArgv from 'string-argv'
import yargs, { CommandModule } from 'yargs'
import { spawn } from 'child_process'
import _ from 'lodash'
import { EventSubChannelRedemptionAddEvent, EventSubChannelRedemptionAddEventData } from '@twurple/eventsub/lib/events/EventSubChannelRedemptionAddEvent'

export type DirectAdapterConfig = {
  adapterType: 'direct'
  adapter: DirectConnectionAdapterConfig
}
export type ProxyAdapterConfig = {
  adapterType: 'proxy'
  adapter: ReverseProxyAdapterConfig
}
export type AdapterConfig = DirectAdapterConfig | ProxyAdapterConfig

export type UserAuthConfig = {
  authType: 'user',
  auth: AuthServerConfig
}
type ClientAuth = {
  clientId: string
  clientSecret: string
  impliedScopes?: string[]
}
export type AppAuthConfig = {
  authType: 'app',
  auth: ClientAuth
}
export type AuthConfig = UserAuthConfig | AppAuthConfig

export type Config = {

  secret: string
  /** if you don't want to have your webhook listen directly to 443 (I'd recommend some apache2 proxy in front of this) */
  port?: number
  /** your user id
   * @see https://google.com/search?q=twitch+user+id */
  user: string
  appAuth: ClientAuth
  userAuth: AuthServerConfig
  upId: string
  downId :string
} & AdapterConfig

export enum EventName {
  SUB = 'sub',
  CHEER = 'cheer',
  GIFTSUB = 'giftsub',
  POINTSUP = 'pointsUp',
  POINTSDOWN = 'pointsDown'
}

export class CaesarEventSub {
  private appAuth: ClientCredentialsAuthProvider
  private userAuth: AuthServer
  private apiClient: ApiClient
  private adapter: ConnectionAdapter
  private listener: EventSubListener
  private event: EventEmitter = new EventEmitter()
  private userId: string
  private downId : string
  private upId: string

  constructor (private config: Config) {
    this.appAuth = new ClientCredentialsAuthProvider(this.config.appAuth.clientId, this.config.appAuth.clientSecret, this.config.appAuth.impliedScopes)
    this.userAuth = new AuthServer(this.config.userAuth)
    this.upId = this.config.upId
    this.downId = this.config.downId

    this.apiClient = new ApiClient({
      authProvider: this.appAuth
    })

    switch (this.config.adapterType) {
      case 'direct':
        this.adapter = new DirectConnectionAdapter(this.config.adapter)
        break
      case 'proxy':
        this.adapter = new ReverseProxyAdapter(this.config.adapter)
        break
    }
    this.listener = new EventSubListener({
      adapter: this.adapter,
      apiClient: this.apiClient,
      secret: this.config.secret
    })
  }

  private subscriptions:Map<string, EventSubSubscription> = new Map()

  on (event: EventName.GIFTSUB, listener: (event: EventSubChannelSubscriptionGiftEvent) => any): void
  on (event: EventName.SUB, listener: (event: EventSubChannelSubscriptionEvent) => any): void
  on (event: EventName.CHEER, listener: (event: EventSubChannelCheerEvent) => any): void
  on (event: EventName.POINTSUP, listener: (event: EventSubChannelRedemptionAddEvent) => any) :void
  on (event: EventName.POINTSDOWN, listener: (event: EventSubChannelRedemptionAddEvent) => any) :void
  on (event: EventName, listener: (...args: any[]) => any) {
    this.event.on(event, listener)
  }

  private async handleSub (name: string, fn: () => Promise<EventSubSubscription>) {
    try {
      const sub = await fn()
      console.log('eventsub', name, 'initialized')
      this.subscriptions.set(name, sub)
    } catch (err) {
      console.error('failed to initialize sub', name, 'reason:', err)
    }
  }

  async init () {
    await this.userAuth.getAccessToken()
    console.log('user token received')

    const user = await this.apiClient.users.getUserByName(this.config.user)
    if (!user) throw new Error('can\'t find user by name: ' + this.config.user)

    console.log('id for user', this.config.user, 'is', user.id)
    this.userId = user.id

    await this.apiClient.eventSub.deleteAllSubscriptions()
    console.log('deleted all subscriptions')

    await this.listener.listen()
    .then(() => console.log('webhook for eventsubs is listening'))
    .catch(err => { console.log('listener failed to listen', err) })

    this.handleSub('sub', () => this.listener.subscribeToChannelSubscriptionEvents({ id: this.userId }, e => {
      // do something when a subscription was received
      console.log(e.userDisplayName, 'subscribed with a tier', e.tier, 'subscription')
      this.event.emit(EventName.SUB, e)
    }))

    this.handleSub('giftsub', () => this.listener.subscribeToChannelSubscriptionGiftEvents({ id: this.userId }, e => {
      // do something when a sub was gifted
      console.log(e.gifterDisplayName, 'gifted', e.amount || 1, 'tier', e.tier, 'subscriptions')
      this.event.emit(EventName.GIFTSUB, e)
    }))

    this.handleSub('cheer', () => this.listener.subscribeToChannelCheerEvents({ id: this.userId }, e => {
      // do something when bits have been cheered
      console.log(e.userDisplayName, 'cheered', e.bits, 'with message:', e.message)
      this.event.emit(EventName.CHEER, e)
    }))

    this.handleSub('pointsDown', () => this.listener.subscribeToChannelRedemptionAddEventsForReward({id: this.userId}, this.downId, e => {
      console.log(e.userDisplayName, 'redeemed Power Down with this message:', e.input)
      this.event.emit(EventName.POINTSDOWN, e)
    }))

    this.handleSub('pointsUp', () => this.listener.subscribeToChannelRedemptionAddEventsForReward({id: this.userId}, this.upId, e => {
      console.log(e.userDisplayName, 'redeemed Power Up with this message:', e.input)
      this.event.emit(EventName.POINTSUP, e)
    }))

    this.prompt()
  }

  private command(arg: string[] | string) {
    return new Promise<Record<string, any>>((resolve, reject) => {
      let y = yargs()

      y = y.scriptName('')

      const subsGetCommand:CommandModule<any, any> = {
        command: 'get',
        describe: 'shows the subscriptions',
        handler: () => this.apiClient.eventSub.getSubscriptions()
          .then(result => {
            console.log(result.total, 'subscriptions:')
            const ml = String(result.data.length).length
            result.data.forEach((sub, i, arr) => console.log(String(i + 1).padStart(ml) + ':', _.pick(sub, ['type', 'status'])))
          })
      }

      const subsListCommand:CommandModule<any, any> = {
        command: 'list',
        aliases: ['l', 'ls'],
        describe: 'lists all available eventsubs',
        handler: () => Array.from(this.subscriptions.entries())
          .forEach(([name, sub]) => console.log('-', name))
      }

      const subsTestCommand:CommandModule<any, any> = {
        command: 'test <name>',
        aliases: ['t'],
        describe: 'executes a test command for the given eventsub',
        builder: cmd => cmd
          .positional('name', {
            type: 'string'
          }),
        handler: async args => {
          const sub = this.subscriptions.get(args.name)
          if (!sub) {
            console.log('you need to tell me what subscription you want, available are:', Array.from(this.subscriptions.keys()))
            return
          }

          const test = await sub.getCliTestCommand()
          const [cmd, ...cmdArgs] = stringArgv(test)
          await new Promise<number>((resolve, reject) => {
            const cp = spawn(cmd, cmdArgs, { stdio: 'inherit' })
            cp.on('exit', code => resolve(code))
            cp.on('error', err => reject(err))
          })
        }
      }

      const subsCommand:CommandModule<any, any> = {
        command: 'subs',
        aliases: ['eventsub', 'es', 's'],
        describe: 'do stuff with eventsubs',
        builder: cmd => cmd
          .command(subsGetCommand)
          .command(subsListCommand)
          .command(subsTestCommand),
        handler: () => {}
      }
      y = y.command(subsCommand)

      y.parse(arg, { }, (err, argv, output) => {
        if (output) {
          console.log(output)
        }
        if (err) return reject(err)
        resolve (argv)
      })
    })
  }

  prompt () {
    process.stdin.on('data', chunk => {
      // const args = stringArgv(chunk.toString())
      // this.command([...args, undefined])
      this.command(chunk.toString())
    })
  }

  async stop () {
    for (const [name, sub] of Array.from(this.subscriptions.entries())) {
      await sub.stop()
      console.log('eventsub', name, 'stopped')
    }
    await this.listener.unlisten()
    console.log('stopped listening')
  }
}
