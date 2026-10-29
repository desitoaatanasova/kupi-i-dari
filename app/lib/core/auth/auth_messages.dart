import '../api/api_exception.dart';

/// Bulgarian user-facing messages for backend error codes.
///
/// Only stable, documented codes are mapped; anything else falls back to a
/// generic message so SQL errors, stack traces and other internals never
/// reach the UI.
abstract class AuthMessages {
  static const String fallback = 'Възникна неочаквана грешка. Опитайте отново.';
  static const String invalidVolunteerCredentials =
      'Грешно име, фамилия или телефон.';

  static String forCode(String code) {
    switch (code) {
      case 'INVALID_CREDENTIALS':
        return 'Грешен телефон или парола.';
      case 'ACCOUNT_DISABLED':
        return 'Този профил е деактивиран. Обърнете се към организатор.';
      case 'VALIDATION_ERROR':
        return 'Проверете въведените данни.';
      case 'UNAUTHORIZED':
        return 'Сесията изтече. Влезте отново.';
      case 'MUST_CHANGE_PASSWORD':
        return 'Изисква се смяна на паролата, преди да продължите.';
      case 'RATE_LIMITED':
        return 'Твърде много опити. Изчакайте малко и опитайте отново.';
      case 'SHIFT_NOT_OPEN':
        return 'Смяната не е отворена за отчитане.';
      case 'REGISTRATION_REQUIRED':
        return 'Трябва да сте записани за тази смяна, за да отчетете количества.';
      case 'ENTRY_WINDOW_CLOSED':
        return 'Времето за отчитане на тази смяна е изтекло.';
      case 'LOCATION_NOT_IN_SHIFT':
        return 'Избраният пункт не е част от тази смяна.';
      case 'ROLE_NOT_VOLUNTEER':
        return 'Само доброволци могат да отчитат количества през тази смяна.';
      case 'ALREADY_REGISTERED':
        return 'Вече сте записани за тази смяна.';
      case 'INVALID_LOCATION':
        return 'Един или повече избрани пунктове липсват или са архивирани.';
      case 'SHIFT_NOT_EDITABLE':
        return 'Тази смяна вече не може да бъде редактирана.';
      case 'INVALID_STATUS_TRANSITION':
        return 'Тази промяна на статуса не е разрешена.';
      case 'NAME_TAKEN':
        return 'Пункт с това име вече съществува.';
      case 'PHONE_TAKEN':
        return 'Телефонният номер вече се използва.';
      case 'SELF_DEACTIVATION':
        return 'Не можете да деактивирате собствения си профил.';
      case 'LAST_ADMIN':
        return 'Последният активен администратор не може да бъде деактивиран.';
      case 'FORBIDDEN':
        return 'Нямате права да извършите това действие.';
      case 'NOT_FOUND':
        return 'Търсеният ресурс не е намерен.';
      case 'UNEXPECTED_RESPONSE':
        return 'Сървърът върна неочакван отговор. Опитайте отново.';
      case ApiException.networkErrorCode:
        return 'Няма връзка със сървъра. Проверете интернет връзката.';
      default:
        return fallback;
    }
  }

  static String forException(ApiException exception) => forCode(exception.code);
}
