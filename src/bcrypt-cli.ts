import yargs from 'yargs'
import bcrypt from 'bcrypt'
import prompts from 'prompts'

export async function main () {
  const argv = await yargs
    .option('rounds', { type: 'number', default: 10 })
    .option('salt', { type: 'string' })
    .argv

  const { password, repeatPassword } = await prompts([{
    name: 'password',
    type: 'password',
    message: 'Enter Password:',
  }, {
    name: 'repeatPassword',
    type: 'password',
    message: 'Repeat Password'
  }])

  if (password !== repeatPassword) {
    console.error('passwords do not match')
  }

  console.log(await bcrypt.hash(password, argv.salt || argv.rounds))
}

main().catch(err => console.error(err))
